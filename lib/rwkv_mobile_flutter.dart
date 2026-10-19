// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ffi';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:path_provider/path_provider.dart';
import 'package:rwkv_mobile_flutter/from_rwkv.dart';
import 'package:rwkv_mobile_flutter/func.dart';
import 'package:rwkv_mobile_flutter/to_rwkv.dart';
import 'package:rwkv_mobile_flutter/types.dart';
import 'package:rwkv_mobile_flutter/rwkv_mobile_ffi.dart';

typedef _FromFrontend = ToRWKV;

const _codec = Utf8Codec(allowMalformed: true);

class RWKVMobile {
  Isolate? _isolate;

  // TODO: 对 Frontend 隐藏 sendPort
  Future<void> runIsolate(StartOptions options) async {
    if (_isolate != null) throw Exception('😡 Isolate already running');
    _isolate = await Isolate.spawn(_isolateMain, options);
  }

  static DynamicLibrary _getDynamicLibrary() {
    if (Platform.isAndroid) return DynamicLibrary.open('librwkv_mobile.so');
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isMacOS) return DynamicLibrary.open('librwkv_mobile.dylib');
    if (Platform.isWindows) {
      final abi = Abi.current();
      if (abi == Abi.windowsX64) return DynamicLibrary.open('rwkv_mobile.dll');
      if (abi == Abi.windowsArm64) return DynamicLibrary.open('rwkv_mobile-arm64.dll');
      throw Exception('😡 Unsupported ABI: ${abi.toString()}');
    }
    if (Platform.isLinux) {
      final abi = Abi.current();
      if (abi == Abi.linuxX64) return DynamicLibrary.open('librwkv_mobile-linux-x86_64.so');
      if (abi == Abi.linuxArm64) return DynamicLibrary.open('librwkv_mobile-linux-aarch64.so');
      throw Exception('😡 Unsupported ABI: ${abi.toString()}');
    }
    throw Exception('😡 Unsupported platform');
  }

  static String getAvailableBackendNames() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    const backendNamesLength = 128;
    final responseBuffer = calloc<Char>(backendNamesLength);
    try {
      final result = rwkvMobile.rwkvmobile_runtime_get_available_backend_names(responseBuffer, backendNamesLength);
      if (result != 0) throw Exception('😡 Failed to list available backends: $result');
      return responseBuffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(responseBuffer);
    }
  }

  static String getPlatformName() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final platformName = rwkvMobile.rwkvmobile_get_platform_name();
    return platformName.cast<Utf8>().toDartString();
  }

  static String getSocName() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final socName = rwkvMobile.rwkvmobile_get_soc_name();
    return socName.cast<Utf8>().toDartString();
  }

  static String getSocPartname() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final socPartname = rwkvMobile.rwkvmobile_get_soc_partname();
    return socPartname.cast<Utf8>().toDartString();
  }

  static String getSnapdragonHtpArch() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final snapdragonHtpArch = rwkvMobile.rwkvmobile_get_htp_arch();
    return snapdragonHtpArch.cast<Utf8>().toDartString();
  }

  static String getRWKVMobileCommitHash() {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final commitHash = rwkvMobile.rwkvmobile_get_commit_hash();
    return commitHash.cast<Utf8>().toDartString();
  }

  static int convertPthToSafetensors(String pthPath, String stPath) {
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());
    final retVal = rwkvMobile.rwkvmobile_convert_pth_to_safetensors(
      pthPath.toNativeUtf8().cast<Char>(),
      stPath.toNativeUtf8().cast<Char>(),
    );
    if (retVal != 0) throw Exception('😡 Failed to convert PTH to safetensors: $retVal');
    return retVal;
  }

  void _isolateMain(StartOptions options) async {
    final sendPort = options.sendPort;
    final rootIsolateToken = options.rootIsolateToken;
    final receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

    // TODO: We can call this when the app is launched, rather than when the model is selected
    // TODO: We can load the runtime in the future. Only Apple cannot.
    final rwkvMobile = rwkv_mobile(_getDynamicLibrary());

    if (kDebugMode) {
      const logLevel = int.fromEnvironment('logLevel', defaultValue: RWKV_LOG_LEVEL_DEBUG);
      rwkvMobile.rwkvmobile_set_loglevel(logLevel);

      print('rwkv-mobile version: ${getRWKVMobileCommitHash()}');
    }

    // definitions
    int maxLength = 2000;
    int maxMessages = 1000;
    int generationStopToken = 0; // Takes effect in 'generation' mode; not used in 'chat' mode
    int retVal = 0;
    int maxBatchSize = 20;

    Pointer<Pointer<Char>> inputsPtr = malloc.allocate<Pointer<Char>>(maxMessages * sizeOf<Pointer<Char>>());
    Pointer<Pointer<Pointer<Char>>> inputsBatchPtr = malloc.allocate<Pointer<Pointer<Char>>>(
      maxBatchSize * sizeOf<Pointer<Pointer<Char>>>(),
    );
    Pointer<Int> numInputsBatchPtr = malloc.allocate<Int>(maxBatchSize * sizeOf<Int>());
    Pointer<Int> forceLangsBatchPtr = malloc.allocate<Int>(maxBatchSize * sizeOf<Int>());
    for (var i = 0; i < maxBatchSize; i++) {
      inputsBatchPtr[i] = malloc.allocate<Pointer<Char>>(maxMessages * sizeOf<Pointer<Char>>());
    }
    Pointer<Pointer<Char>> inputsBatchPtrCompletionAsync = malloc.allocate<Pointer<Char>>(maxBatchSize * sizeOf<Pointer<Char>>());
    List<int> ttsStreamingBufferList = [];
    List<double> ttsStreamingBufferListDouble = [];

    rwkvmobile_runtime_t runtime = rwkvMobile.rwkvmobile_runtime_init();

    if (runtime.address == 0) throw Exception('😡 Failed to initialize runtime');

    final tempDir = await getTemporaryDirectory();
    rwkvMobile.rwkvmobile_set_cache_dir(runtime, tempDir.path.ptr);

    // TODO: @WangCe 逐渐地迁移到 handler 方法中, 最好不要在该方法声明局部变量
    await for (final _FromFrontend message in receivePort) {
      switch (message) {
        // 🟥 setMaxLength
        case SetMaxLength req:
          final arg = req.maxLength;
          if (arg > 0) maxLength = arg;

        // 🟥 clearStates
        case ClearStates req:
          rwkvMobile.rwkvmobile_runtime_clear_state(runtime, req.modelID);

        // 🟥 unloadInitialStates
        case UnloadInitialStates req:
          rwkvMobile.rwkvmobile_runtime_unload_initial_state(runtime, req.modelID, req.statePath.ptr);

        // 🟥 loadInitialStates
        case LoadInitialStates req:
          final statePathPtr = req.statePath.ptr;
          rwkvMobile.rwkvmobile_runtime_load_initial_state(runtime, req.modelID, statePathPtr);

        // 🟥 setGenerationStopToken
        case SetGenerationStopToken req:
          final arg = req.stopToken;
          if (arg >= 0) generationStopToken = arg;

        // 🟥 setPrompt
        case SetPrompt req:
          final promptPtr = req.prompt.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_prompt(runtime, req.modelID, promptPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set prompt: return value: $retVal', req));

        // 🟥 getPrompt
        case GetPrompt req:
          final stringBuffer = malloc.allocate<Char>(maxLength);
          rwkvMobile.rwkvmobile_runtime_get_prompt(runtime, req.modelID, stringBuffer, maxLength);
          final prompt = stringBuffer.cast<Utf8>().toDartString();
          sendPort.send(CurrentPrompt(prompt: prompt, req: req));
          malloc.free(stringBuffer);

        // 🟥 setSamplerParams
        case SetSamplerParams req:
          final samplerParams = Struct.create<sampler_params>();
          final penaltyParams = Struct.create<penalty_params>();
          samplerParams.temperature = req.temperature.toDouble();
          samplerParams.top_k = req.topK.toInt();
          samplerParams.top_p = req.topP.toDouble();
          penaltyParams.presence_penalty = req.presencePenalty.toDouble();
          penaltyParams.frequency_penalty = req.frequencyPenalty.toDouble();
          penaltyParams.penalty_decay = req.penaltyDecay.toDouble();
          rwkvMobile.rwkvmobile_runtime_set_sampler_params(runtime, req.modelID, samplerParams);
          rwkvMobile.rwkvmobile_runtime_set_penalty_params(runtime, req.modelID, penaltyParams);

        // 🟥 getSamplerParams
        case GetSamplerParams req:
          final samplerParams = rwkvMobile.rwkvmobile_runtime_get_sampler_params(runtime, req.modelID);
          final penaltyParams = rwkvMobile.rwkvmobile_runtime_get_penalty_params(runtime, req.modelID);
          sendPort.send(
            SamplerParams(
              temperature: samplerParams.temperature,
              topK: samplerParams.top_k,
              topP: samplerParams.top_p,
              presencePenalty: penaltyParams.presence_penalty,
              frequencyPenalty: penaltyParams.frequency_penalty,
              penaltyDecay: penaltyParams.penalty_decay,
              req: req,
            ),
          );

        // 🟥 setSeed
        case SetSeed req:
          final seed = req.seed;
          retVal = rwkvMobile.rwkvmobile_runtime_set_seed(runtime, req.modelID, seed);
          if (retVal != 0) sendPort.send(Error('Failed to set seed: retVal: $retVal', req, retVal));

        // 🟥 getSeed
        case GetSeed req:
          final seed = rwkvMobile.rwkvmobile_runtime_get_seed(runtime, req.modelID);
          sendPort.send(CurrentSeed(seed: seed, modelID: req.modelID, req: req));

        // 🟥 getIsGenerating
        case GetIsGenerating req:
          final modelID = req.modelID;
          bool isGeneratingBool = (rwkvMobile.rwkvmobile_runtime_is_generating(runtime, modelID) != 0);
          sendPort.send(IsGenerating(isGenerating: isGeneratingBool, modelID: modelID, req: req));
          sendPort.send({'isGenerating': isGeneratingBool});

        // 🟥 setThinkingToken
        case SetThinkingToken req:
          final thinkingTokenPtr = req.thinkingToken.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_thinking_token(runtime, req.modelID, thinkingTokenPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set thinking token', req));

        // 🟥 setEosToken
        case SetEosToken req:
          final eosTokenPtr = req.eosToken.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_eos_token(runtime, req.modelID, eosTokenPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set eos token', req));

        // 🟥 setBosToken
        case SetBosToken req:
          final bosTokenPtr = req.bosToken.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_bos_token(runtime, req.modelID, bosTokenPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set bos token', req));

        // 🟥 setTokenBanned
        case SetTokenBanned req:
          Pointer<Int> tokenBannedPtr = malloc.allocate<Int>(req.tokenBanned.length * sizeOf<Int>());
          for (var i = 0; i < req.tokenBanned.length; i++) {
            tokenBannedPtr[i] = req.tokenBanned[i];
          }
          retVal = rwkvMobile.rwkvmobile_runtime_set_token_banned(runtime, req.modelID, tokenBannedPtr, req.tokenBanned.length);
          malloc.free(tokenBannedPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set token banned: retVal: $retVal', req, retVal));

        // 🟥 setUserRole
        case SetUserRole req:
          final userRolePtr = req.userRole.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_user_role(runtime, req.modelID, userRolePtr);
          if (retVal != 0) sendPort.send(Error('Failed to set user role: retVal: $retVal', req, retVal));

        // 🟥 setResponseRole
        case SetResponseRole req:
          final responseRolePtr = req.responseRole.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_response_role(runtime, req.modelID, responseRolePtr);
          if (retVal != 0) sendPort.send(Error('Failed to set response role: retVal: $retVal', req, retVal));

        // 🟥 setSpaceAfterRoles
        case SetSpaceAfterRoles req:
          retVal = rwkvMobile.rwkvmobile_runtime_set_space_after_roles(runtime, req.modelID, req.spaceAfterRoles ? 1 : 0);
          if (retVal != 0) sendPort.send(Error('Failed to set space after roles: retVal: $retVal', req, retVal));

        case SetFlowerTemplate req:
          retVal = rwkvMobile.rwkvmobile_runtime_set_flower_template(runtime, req.modelID, req.flowerTemplate ? 1 : 0);
          if (retVal != 0) sendPort.send(Error('Failed to set flower template: retVal: $retVal', req, retVal));

        case SetImageUniqueIdentifier req:
          final uniqueIdentifierPtr = req.uniqueIdentifier.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_image_unique_identifier(runtime, uniqueIdentifierPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set image unique identifier: retVal: $retVal', req, retVal));

        // 🟥 loadVisionEncoder
        case LoadVisionEncoder req:
          final encoderPathPtr = req.encoderPath.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_load_vision_encoder(runtime, req.modelID, encoderPathPtr);
          if (retVal != 0) sendPort.send(Error('Failed to load vision encoder: retVal: $retVal', req, retVal));

        // 🟥 loadVisionEncoderAndAdapter
        case LoadVisionEncoderAndAdapter req:
          final encoderPathPtr = req.encoderPath.ptr;
          final adapterPathPtr = req.adapterPath.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_load_vision_encoder_and_adapter(runtime, req.modelID, encoderPathPtr, adapterPathPtr);
          if (retVal != 0) sendPort.send(Error('Failed to load vision encoder and adapter: retVal: $retVal', req, retVal));

        // 🟥 releaseVisionEncoder
        case ReleaseVisionEncoder req:
          retVal = rwkvMobile.rwkvmobile_runtime_release_vision_encoder(runtime, req.modelID);
          if (retVal != 0) sendPort.send(Error('Failed to release vision encoder', req, retVal));

        // 🟥 setVisionPrompt
        case SetVisionPrompt req:
          // final imagePathPtr = req.imagePathPtr.p;
          // retVal = rwkvMobile.rwkvmobile_runtime_set_image_prompt(runtime, model_id, imagePathPtr);
          sendPort.send(Error('Failed to set image prompt', req, retVal));

        // 🟥 loadWhisperEncoder
        case LoadWhisperEncoder req:
          final encoderPathPtr = req.encoderPath.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_load_whisper_encoder(runtime, req.modelID, encoderPathPtr);
          if (retVal != 0) sendPort.send(Error('Failed to load whisper encoder', req, retVal));

        // 🟥 releaseWhisperEncoder
        case ReleaseWhisperEncoder req:
          retVal = rwkvMobile.rwkvmobile_runtime_release_whisper_encoder(runtime, req.modelID);
          if (retVal != 0) sendPort.send(Error('Failed to release whisper encoder', req, retVal));

        // 🟥 setAudioPrompt
        case SetAudioPrompt req:
          final audioPathPtr = req.audioPathPtr.ptr;
          retVal = rwkvMobile.rwkvmobile_runtime_set_audio_prompt(runtime, req.modelID, audioPathPtr);
          if (retVal != 0) sendPort.send(Error('Failed to set audio prompt', req, retVal));

        // 🟥 message
        case ChatAsync req:
          final finalMaxLength = req.maxLength ?? maxLength;
          final numInputs = req.messages.length;

          if (numInputs > maxMessages) {
            final error = 'Message count $numInputs exceeds max message count $maxMessages';
            sendPort.send(Error(error, req, -1));
            sendPort.send(GenerateStop(error: error, req: req));
            break;
          }

          if (rwkvMobile.rwkvmobile_runtime_is_generating(runtime, req.modelID) != 0) {
            sendPort.send(Error('LLM is already generating', req, retVal));
            break;
          }

          var allocatedInputs = 0;
          try {
            for (var i = 0; i < numInputs; i++) {
              inputsPtr[i] = req.messages[i].ptr;
              allocatedInputs++;
            }
            sendPort.send(GenerateStart(req: req));
            retVal = rwkvMobile.rwkvmobile_runtime_eval_chat_with_history_async(
              runtime,
              req.modelID,
              inputsPtr,
              numInputs,
              finalMaxLength,
              nullptr,
              req.enableReasoning ? 1 : 0,
              req.forceReasoning ? 1 : 0,
              req.forceLang ?? FORCE_LANG_NONE,
              req.addGenerationPrompt ? 1 : 0,
            );
          } finally {
            // The native entrypoint copies every input before launching its worker.
            for (var i = 0; i < allocatedInputs; i++) {
              malloc.free(inputsPtr[i]);
              inputsPtr[i] = nullptr;
            }
          }
          if (retVal != 0) sendPort.send(GenerateStop(error: 'Failed to start generation thread: retVal: $retVal', req: req));

        case ChatBatchAsync req:
          final batchSize = req.batchSize;
          final finalMaxLength = req.maxLength ?? maxLength;

          if (batchSize <= 0) {
            sendPort.send(Error('Invalid batch size: $batchSize', req, -1));
            break;
          }

          if (batchSize > maxBatchSize) {
            sendPort.send(Error('Batch size $batchSize exceeds max batch size $maxBatchSize', req, -1));
            break;
          }

          if (batchSize != req.messages.length) {
            sendPort.send(Error('Batch size does not match messages length', req, -1));
            break;
          }

          if (req.messages.any((messages) => messages.length > maxMessages)) {
            final error = 'Message count exceeds max message count $maxMessages';
            sendPort.send(Error(error, req, -1));
            sendPort.send(GenerateStop(error: error, req: req));
            break;
          }

          late final List<int> forceLangs;
          try {
            forceLangs = req.resolvedForceLangs(noneValue: FORCE_LANG_NONE);
          } catch (e) {
            sendPort.send(Error('Invalid forceLangs: $e', req, -1));
            break;
          }

          if (rwkvMobile.rwkvmobile_runtime_is_generating(runtime, req.modelID) != 0) {
            sendPort.send(Error('LLM is already generating', req, retVal));
            break;
          }

          final allocatedInputs = <Pointer<Char>>[];
          try {
            for (var i = 0; i < batchSize; i++) {
              if (inputsBatchPtr[i] == nullptr) {
                inputsBatchPtr[i] = calloc.allocate<Pointer<Char>>(maxMessages * sizeOf<Pointer<Char>>());
              }
              for (var j = 0; j < req.messages[i].length; j++) {
                final pointer = req.messages[i][j].ptr;
                allocatedInputs.add(pointer);
                inputsBatchPtr[i][j] = pointer;
              }
              numInputsBatchPtr[i] = req.messages[i].length;
              forceLangsBatchPtr[i] = forceLangs[i];
            }
            sendPort.send(GenerateStart(req: req));
            retVal = rwkvMobile.rwkvmobile_runtime_eval_chat_batch_with_history_async(
              runtime,
              req.modelID,
              inputsBatchPtr,
              numInputsBatchPtr,
              batchSize,
              finalMaxLength,
              nullptr,
              req.enableReasoning ? 1 : 0,
              req.forceReasoning ? 1 : 0,
              forceLangsBatchPtr,
              req.addGenerationPrompt ? 1 : 0,
            );
          } finally {
            // The batch entrypoint also copies all strings before returning.
            for (final pointer in allocatedInputs) {
              malloc.free(pointer);
            }
          }
          if (retVal != 0) sendPort.send(GenerateStop(error: 'Failed to start generation thread: retVal: $retVal', req: req));

        // 🟥 getSupportedBatchSizes
        case GetSupportedBatchSizes req:
          final supportedBatchSizes = rwkvMobile.rwkvmobile_runtime_get_supported_batch_sizes(runtime, req.modelID);
          final List<int> batchSizes = [];
          for (var i = 0; i < supportedBatchSizes.length; i++) {
            if (supportedBatchSizes.sizes[i] > 1) {
              // we don't actually need to use batch size 1, so we skip it
              batchSizes.add(supportedBatchSizes.sizes[i]);
            }
          }
          sendPort.send(SupportedBatchSizes(supportedBatchSizes: batchSizes, req: req));

        // 🟥 generateAsync
        case GenerateAsync req:
          final promptPtr = req.prompt.ptr;
          final finalMaxLength = req.maxLength ?? maxLength;
          final finalStopToken = req.stopToken ?? generationStopToken;
          final disableCache = (req.disableCache ?? false) ? 1 : 0;

          if (req.batch > maxBatchSize) {
            sendPort.send(Error('Batch size ${req.batch} exceeds max batch size $maxBatchSize', req, -1));
            break;
          }

          if (rwkvMobile.rwkvmobile_runtime_is_generating(runtime, req.modelID) != 0) {
            sendPort.send(Error('LLM is already generating', req));
            break;
          }

          sendPort.send(GenerateStart(req: req));
          if (req.batch <= 1) {
            retVal = rwkvMobile.rwkvmobile_runtime_gen_completion_async(
              runtime,
              req.modelID,
              promptPtr,
              finalMaxLength,
              finalStopToken,
              nullptr,
              disableCache,
            );
          } else {
            for (var i = 0; i < req.batch; i++) {
              inputsBatchPtrCompletionAsync[i] = promptPtr;
            }
            retVal = rwkvMobile.rwkvmobile_runtime_gen_completion_batch_async(
              runtime,
              req.modelID,
              inputsBatchPtrCompletionAsync,
              req.batch,
              finalMaxLength,
              generationStopToken,
              nullptr,
              disableCache,
            );
          }
          if (retVal != 0) {
            sendPort.send(GenerateStop(error: 'Failed to start generation: retVal: $retVal', req: req));
          }

        // 🟥 runEvaluation
        case RunEvaluation req:
          final sourceTextPtr = req.sourceText.ptr;
          final targetTextPtr = req.targetText.ptr;
          final evaluationResults = rwkvMobile.rwkvmobile_runtime_run_evaluation(runtime, req.modelID, sourceTextPtr, targetTextPtr);
          final List<double> logits = evaluationResults.logits_vals.asTypedList(evaluationResults.count).toList();
          final List<bool> corrects = evaluationResults.corrects
              .cast<Int32>()
              .asTypedList(evaluationResults.count)
              .toList()
              .map((e) => e != 0)
              .toList();
          List<String> outputTexts = [];
          for (var i = 0; i < evaluationResults.count; i++) {
            outputTexts.add(evaluationResults.output_texts[i].cast<Utf8>().toDartString());
          }
          sendPort.send(EvaluationResults(logits: logits, corrects: corrects, outputTexts: outputTexts, req: req));
          rwkvMobile.rwkvmobile_runtime_free_evaluation_results(evaluationResults);

        // 🟥 generate
        case SudokuOthelloGenerate req:
          final promptPtr = req.prompt.ptr;
          String responseStr = req.prompt;
          final randon = Random();
          final wantRawJSON = req.wantRawJSON;
          final decodeStream = req.decodeStream;

          callbackFunction(Pointer<Char> cppStream, int idx, Pointer<Char> cppNewText) {
            // final start = DateTime.now().microsecondsSinceEpoch;
            final showQuerySpeed = (randon.nextDouble() * 100) <= 3;
            final prefillSpeed = showQuerySpeed ? rwkvMobile.rwkvmobile_runtime_get_avg_prefill_speed(runtime, req.modelID) : -1.0;
            final decodeSpeed = showQuerySpeed ? rwkvMobile.rwkvmobile_runtime_get_avg_decode_speed(runtime, req.modelID) : -1.0;

            final newText = cppNewText.cast<Utf8>().toDartString();

            late final String stream;

            if (decodeStream) {
              stream = cppStream.cast<Utf8>().toDartString();
              responseStr = stream;
            } else {
              stream = '';
            }

            // TODO: @wangce 移除该调用
            if (wantRawJSON) {
              sendPort.send({
                'streamResponse': stream,
                'streamResponseToken': idx,
                'streamResponseNewText': newText,
                'prefillSpeed': prefillSpeed,
                'decodeSpeed': decodeSpeed,
              });
            }

            sendPort.send(
              StreamResponse(
                streamResponse: stream,
                streamResponseToken: idx,
                streamResponseNewText: newText,
                prefillSpeed: prefillSpeed,
                decodeSpeed: decodeSpeed,
                req: req,
              ),
            );
          }

          final nativeCallable = NativeCallable<Void Function(Pointer<Char>, Int, Pointer<Char>)>.isolateLocal(callbackFunction);
          sendPort.send(GenerateStart(req: req));
          retVal = rwkvMobile.rwkvmobile_runtime_gen_completion(
            runtime,
            req.modelID,
            promptPtr,
            maxLength,
            generationStopToken,
            nativeCallable.nativeFunction,
            1,
          );
          if (retVal != 0) sendPort.send(GenerateStop(error: 'Failed to start generation: retVal: $retVal', req: req));

          sendPort.send({'sudokuOthelloResponse': responseStr});
          if (retVal == 0) sendPort.send(GenerateStop(req: req));

        // 🟥 releaseRWKVModel
        case ReleaseRWKVModel req:
          sendPort.send(LoadModelSteps(modelID: req.modelID, req: req, status: LoadingStatus.releasing));
          final retVal = rwkvMobile.rwkvmobile_runtime_release_model(runtime, req.modelID);

          if (retVal != 0) {
            sendPort.send(Error('Failed to release RWKV model', req));
            sendPort.send(
              LoadModelSteps(
                modelID: req.modelID,
                req: req,
                status: LoadingStatus.failedInReleasing,
                info: 'Failed to release RWKV model, retVal: $retVal',
              ),
            );
          } else {
            sendPort.send(LoadModelSteps(modelID: req.modelID, req: req, status: LoadingStatus.released));
          }

        case AddTTSModel req:
          final modelPath = req.modelPath;
          final backend = req.backend;
          final tokenizerPath = req.tokenizerPath;
          final modelID = rwkvMobile.rwkvmobile_runtime_load_model(runtime, modelPath.ptr, backend.asArgument.ptr, tokenizerPath.ptr);
          if (modelID < 0) {
            sendPort.send(Error('Failed to add TTS model', req));
            break;
          }
          final wav2vec2Path = req.wav2vec2Path;
          final bicodecTokenizerPath = req.bicodecTokenizerPath;
          final bicodecDetokenizerPath = req.bicodecDetokenizerPath;
          retVal = rwkvMobile.rwkvmobile_runtime_sparktts_load_models(
            runtime,
            wav2vec2Path.ptr,
            bicodecTokenizerPath.ptr,
            bicodecDetokenizerPath.ptr,
          );
          if (retVal != 0) sendPort.send(Error('Failed to add TTS model', req));
          sendPort.send(LoadModelSteps(req: req, status: LoadingStatus.failedInLoading, info: 'Failed to add TTS model, retVal: $retVal'));
          if (retVal != 0) break;
          sendPort.send(LoadModelSteps(req: req, modelID: modelID, status: LoadingStatus.loaded));

        // 🟥 LoadRWKVModel
        case LoadRWKVModel req:
          String modelPath = req.modelPath;
          final modelBackendString = req.backend.asArgument;
          final backend = req.backend;
          final tokenizerPath = req.tokenizerPath;

          int modelID = -1;
          int retVal = 0;
          Pointer<Void>? loadModelExtra;
          switch (backend) {
            case Backend.ncnn:
            case Backend.mnn:
            case Backend.mlx:
            case Backend.mtkNeuropilot7:
            case Backend.mtkNeuropilot9:
            case Backend.palm:
              sendPort.send(LoadModelSteps(req: req, status: LoadingStatus.loading));
              retVal = rwkvMobile.rwkvmobile_runtime_load_model_async(runtime, modelPath.ptr, modelBackendString.ptr, tokenizerPath.ptr);
            case Backend.llamacpp:
              sendPort.send(LoadModelSteps(req: req, status: LoadingStatus.loadModelWithExtra));
              final llamaCppArgs = calloc<llama_cpp_args>();
              loadModelExtra = llamaCppArgs.cast<Void>();
              // TODO @HaloWang 从前端获取 n_gpu_layers （for windows，有的用户可能会想部分层放gpu或者纯cpu推理）
              llamaCppArgs.ref.n_gpu_layers = req.llamaCppNGpuLayers ?? 99;
              retVal = rwkvMobile.rwkvmobile_runtime_load_model_with_extra_async(
                runtime,
                modelPath.ptr,
                modelBackendString.ptr,
                tokenizerPath.ptr,
                loadModelExtra,
              );
            case Backend.qnn:
              final tempDir = await getTemporaryDirectory();
              final separator = Platform.pathSeparator;
              final qnnLibDirPath = [tempDir.path, 'assets', 'lib', ''].join(separator);
              final qnnHtpLibName = Platform.isWindows ? 'QnnHtp.dll' : 'libQnnHtp.so';
              final qnnHtpLibPath = '$qnnLibDirPath$qnnHtpLibName';
              sendPort.send(LoadModelSteps(req: req, status: LoadingStatus.setQnnLibraryPath));
              rwkvMobile.rwkvmobile_runtime_set_qnn_library_path(runtime, qnnLibDirPath.ptr);

              sendPort.send(LoadModelSteps(req: req, status: LoadingStatus.loadModelWithExtra));
              loadModelExtra = qnnHtpLibPath.toNativeUtf8(allocator: calloc).cast<Void>();
              retVal = rwkvMobile.rwkvmobile_runtime_load_model_with_extra_async(
                runtime,
                modelPath.ptr,
                modelBackendString.ptr,
                tokenizerPath.ptr,
                loadModelExtra,
              );
            case Backend.webRwkv:
              sendPort.send(LoadModelSteps(req: req, status: LoadingStatus.loading));
              final webRwkvArgs = calloc<web_rwkv_args>();
              loadModelExtra = webRwkvArgs.cast<Void>();
              // TODO: @wangce 从前端获取 quant_type 和 quant_layers
              webRwkvArgs.ref.quant_type = 0; // 0: fp16, 1: int8, 2: nf4
              webRwkvArgs.ref.quant_layers = 0; // number of quantized layers
              retVal = rwkvMobile.rwkvmobile_runtime_load_model_with_extra_async(
                runtime,
                modelPath.ptr,
                modelBackendString.ptr,
                tokenizerPath.ptr,
                loadModelExtra,
              );
            case Backend.coreml:
              final coremlArgs = calloc<coreml_args>();
              loadModelExtra = coremlArgs.cast<Void>();
              coremlArgs.ref.load_prefill_async = 1;
              coremlArgs.ref.async_prefill_decode_load_threshold_ms =
                  10000; // do not load prefill functions async when decode loaded under 10000ms(cache hit case)
              retVal = rwkvMobile.rwkvmobile_runtime_load_model_with_extra_async(
                runtime,
                modelPath.ptr,
                modelBackendString.ptr,
                tokenizerPath.ptr,
                loadModelExtra,
              );
          }

          if (retVal != 0) {
            if (loadModelExtra != null) calloc.free(loadModelExtra);
            final error =
                '''Failed to load model: 
path: $modelPath
backend: $modelBackendString
tokenizerPath: $tokenizerPath
modelID: $modelID''';
            sendPort.send(LoadModelSteps(info: error, req: req, status: LoadingStatus.failedInLoading));
            break;
          }

          double lastProgress = 0.0;
          int loadPolls = 0;
          while (rwkvMobile.rwkvmobile_runtime_is_loading_model(runtime) != 0) {
            // Notice completion promptly while keeping progress updates near 200 ms.
            if (loadPolls++ % 10 == 0) {
              double progress = rwkvMobile.rwkvmobile_runtime_get_load_model_progress(runtime);
              if (progress < lastProgress) progress = lastProgress;
              lastProgress = progress;
              sendPort.send(LoadModelSteps(progress: progress, req: req, status: LoadingStatus.loading));
            }
            const duration = Duration(milliseconds: 20);
            await Future.delayed(duration);
          }
          // The native async loader captures `extra` and reads it on its load
          // thread. Keep it alive until that thread reports completion.
          if (loadModelExtra != null) calloc.free(loadModelExtra);

          final ptr0 = malloc.allocate<Int32>(sizeOf<Int32>());
          final ptr1 = malloc.allocate<Int32>(sizeOf<Int32>());
          rwkvMobile.rwkvmobile_runtime_get_load_model_status(runtime, ptr0.cast<Int>(), ptr1.cast<Int>());
          retVal = ptr0.value;
          modelID = ptr1.value;
          malloc.free(ptr0);
          malloc.free(ptr1);
          if (retVal != 0 || modelID < 0) {
            final error =
                '''Failed to load model: 
path: $modelPath
backend: $modelBackendString
tokenizerPath: $tokenizerPath
modelID: $modelID''';
            sendPort.send(LoadModelSteps(info: error, req: req, status: LoadingStatus.failedInLoading));
            break;
          }
          sendPort.send(LoadModelSteps(modelID: modelID, req: req, status: LoadingStatus.loaded));

        // 🟥 stop
        case Stop req:
          bool generating = rwkvMobile.rwkvmobile_runtime_is_generating(runtime, req.modelID) == 1;
          while (generating) {
            rwkvMobile.rwkvmobile_runtime_stop_generation(runtime, req.modelID);
            await Future.delayed(const Duration(milliseconds: 5));
            generating = rwkvMobile.rwkvmobile_runtime_is_generating(runtime, req.modelID) == 1;
            if (!generating) sendPort.send(GenerateStop(req: req));
          }

        case CalculateTokensCountFromMessages req:
          final numInputs = req.messages.length;
          if (numInputs > maxMessages) {
            sendPort.send(Error('Message count $numInputs exceeds max message count $maxMessages', req, -1));
            break;
          }
          var allocatedInputs = 0;
          try {
            for (var i = 0; i < numInputs; i++) {
              inputsPtr[i] = req.messages[i].ptr;
              allocatedInputs++;
            }
            final tokensCount = rwkvMobile.rwkvmobile_runtime_calculate_tokens_count_from_messages(
              runtime,
              req.modelID,
              inputsPtr,
              numInputs,
            );
            sendPort.send(TokensCount(tokensCount: tokensCount, req: req));
          } finally {
            // Token counting reads its copied strings synchronously.
            for (var i = 0; i < allocatedInputs; i++) {
              malloc.free(inputsPtr[i]);
              inputsPtr[i] = nullptr;
            }
          }

        case CalculateTokensCountRaw req:
          final textPtr = req.text.ptr;
          try {
            final tokensCount = rwkvMobile.rwkvmobile_runtime_calculate_tokens_count_from_text(runtime, req.modelID, textPtr);
            sendPort.send(TokensCount(tokensCount: tokensCount, req: req));
          } finally {
            malloc.free(textPtr);
          }

        // 🟥 getResponseBufferContent
        case GetResponseBufferContent req:
          final responseBufferContent = rwkvMobile.rwkvmobile_runtime_get_response_buffer_content(runtime, req.modelID);
          try {
            int length = responseBufferContent.length;
            final Uint8List byteList = responseBufferContent.content.cast<Uint8>().asTypedList(length);
            final String str = _codec.decode(byteList);
            final eosFound = responseBufferContent.eos_found == 1;
            sendPort.send(ResponseBufferContent(responseBufferContent: str, eosFound: eosFound, req: req));
          } finally {
            rwkvMobile.rwkvmobile_runtime_free_response_buffer(responseBufferContent);
          }

        case GetResponseBufferTokensCount req:
          final tokensCount = rwkvMobile.rwkvmobile_runtime_get_response_buffer_tokens_count(runtime, req.modelID);
          sendPort.send(TokensCount(tokensCount: tokensCount, req: req));

        case GetResponseBufferTokensCountBatch req:
          final batchTokensCount = rwkvMobile.rwkvmobile_runtime_get_response_buffer_tokens_count_batch(runtime, req.modelID);
          final tokensCountList = batchTokensCount.counts.asTypedList(batchTokensCount.batch_size).toList();
          sendPort.send(TokensCountBatch(tokensCount: tokensCountList, req: req));

        // 🟥 getBatchResponseBufferContent
        case GetBatchResponseBufferContent req:
          final responseBufferContent = rwkvMobile.rwkvmobile_runtime_get_response_buffer_content_batch(runtime, req.modelID);
          int batchSize = responseBufferContent.batch_size;
          List<String> responseBufferContentList = [];
          List<bool> eosFoundList = [];

          for (int i = 0; i < batchSize; i++) {
            int length = responseBufferContent.lengths[i];
            final Uint8List byteList = responseBufferContent.contents[i].cast<Uint8>().asTypedList(length);
            final String str = _codec.decode(byteList);
            final eosFound = responseBufferContent.eos_founds[i] == 1;
            responseBufferContentList.add(str);
            eosFoundList.add(eosFound);
          }
          rwkvMobile.rwkvmobile_runtime_free_response_buffer_batch(responseBufferContent);
          sendPort.send(
            ResponseBatchBufferContent(
              responseBufferContent: responseBufferContentList,
              eosFound: eosFoundList,
              batchSize: batchSize,
              req: req,
            ),
          );

        // 🟥 getPrefillAndDecodeSpeed
        case GetPrefillAndDecodeSpeed req:
          final modelID = req.modelID;
          final prefillSpeed = rwkvMobile.rwkvmobile_runtime_get_avg_prefill_speed(runtime, modelID);
          final decodeSpeed = rwkvMobile.rwkvmobile_runtime_get_avg_decode_speed(runtime, modelID);
          final progress = rwkvMobile.rwkvmobile_runtime_get_prefill_progress(runtime, modelID);
          sendPort.send(Speed(prefillSpeed: prefillSpeed, decodeSpeed: decodeSpeed, prefillProgress: progress, req: req));

        // 🟥 getResponseBufferIds
        case GetResponseBufferIds req:
          final responseBufferIds = rwkvMobile.rwkvmobile_runtime_get_response_buffer_ids(runtime, req.modelID);
          final responseBufferIdsList = responseBufferIds.ids.asTypedList(responseBufferIds.len).toList();
          rwkvMobile.rwkvmobile_runtime_free_token_ids(responseBufferIds);
          sendPort.send({'responseBufferIds': responseBufferIdsList});

        // 🟥 getLoadedModelIDs
        case GetLoadedModelIDs req:
          final modelIDs = malloc.allocate<Int32>(16 * sizeOf<Int32>());
          final loadedModelIDsList = rwkvMobile.rwkvmobile_runtime_get_loaded_model_ids(runtime, modelIDs.cast<Int>(), 16);
          final loadedModelIDsListList = modelIDs.asTypedList(loadedModelIDsList).toList();
          malloc.free(modelIDs);
          sendPort.send(LoadedModelIDs(loadedModelIDs: loadedModelIDsListList, req: req));

        // 🟥 getLoadedModelPathByID
        case GetLoadedModelPathByID req:
          final modelID = req.modelID;
          final loadedModelPath = rwkvMobile.rwkvmobile_runtime_get_model_path_by_id(runtime, modelID);
          final loadedModelPathString = loadedModelPath.cast<Utf8>().toDartString();
          sendPort.send(LoadedModelPathByID(loadedModelPath: loadedModelPathString, modelID: modelID, req: req));

        case LoadSparkTTSModels req:
          final wav2vec2Path = req.wav2vec2Path;
          final bicodecTokenizerPath = req.bicodecTokenizerPath;
          final bicodecDetokenizerPath = req.bicodecDetokenizerPath;

          retVal = rwkvMobile.rwkvmobile_runtime_sparktts_load_models(
            runtime,
            wav2vec2Path.ptr,
            bicodecTokenizerPath.ptr,
            bicodecDetokenizerPath.ptr,
          );
          if (retVal != 0) sendPort.send(Error('Failed to load Spark TTS models', req));

        // 🟥 loadTTSTextNormalizer
        case LoadTTSTextNormalizer req:
          final fstPath = req.fstPath;
          retVal = rwkvMobile.rwkvmobile_runtime_tts_register_text_normalizer(runtime, fstPath.ptr);
          if (retVal != 0) sendPort.send(Error('Failed to load TTS Text Normalizer file $fstPath', req));

        // 🟥 releaseTTSModels
        case ReleaseTTSModels req:
          retVal = rwkvMobile.rwkvmobile_runtime_sparktts_release_models(runtime);
          if (retVal != 0) sendPort.send(Error('Failed to release TTS models', req));

        // 🟥 runTTSAsync
        case StartTTS req:
          final ttsText = req.ttsText;
          final promptSpeechText = req.promptSpeechText;
          final promptWavPath = req.promptWavPath;
          final outputWavPath = req.outputWavPath;
          ttsStreamingBufferList.clear();
          ttsStreamingBufferListDouble.clear();
          retVal = rwkvMobile.rwkvmobile_runtime_run_spark_tts_streaming_async(
            runtime,
            req.modelID,
            ttsText.ptr,
            promptSpeechText.ptr,
            promptWavPath.ptr,
            outputWavPath.ptr,
          );

          if (retVal != 0) sendPort.send(Error('Failed to run TTS', req));
          if (retVal != 0) break;

          sendPort.send(TTSGenerationStart(start: true, req: req));

        // 🟥 runTTSWithGlobalTokensAsync
        case StartTTSWithGlobalTokens req:
          final ttsText = req.ttsText;
          final outputWavPath = req.outputWavPath;
          ttsStreamingBufferList.clear();
          ttsStreamingBufferListDouble.clear();
          if (req.globalTokens.length != 32) throw Exception('😡 globalTokens length must be 32');
          Pointer<Int32> globalTokensPtr = malloc.allocate<Int32>(req.globalTokens.length * sizeOf<Int32>());
          for (int i = 0; i < req.globalTokens.length; i++) {
            globalTokensPtr[i] = req.globalTokens[i];
          }
          retVal = rwkvMobile.rwkvmobile_runtime_run_spark_tts_with_global_tokens_streaming_async(
            runtime,
            req.modelID,
            ttsText.ptr,
            outputWavPath.ptr,
            globalTokensPtr.cast<Int>(),
          );
          malloc.free(globalTokensPtr);

          if (retVal != 0) sendPort.send(Error('Failed to run TTS', req));
          if (retVal != 0) break;

          sendPort.send(TTSGenerationStart(start: true, req: req));

        // 🟥 runTTSWithPropertiesAsync
        case StartTTSWithProperties req:
          final ttsText = req.ttsText;
          final outputWavPath = req.outputWavPath;
          ttsStreamingBufferList.clear();
          ttsStreamingBufferListDouble.clear();
          retVal = rwkvMobile.rwkvmobile_runtime_run_spark_tts_with_properties_streaming_async(
            runtime,
            req.modelID,
            ttsText.ptr,
            outputWavPath.ptr,
            req.age.asArgument.ptr,
            req.gender.asArgument.ptr,
            req.emotion.asArgument.ptr,
            req.speed.asArgument.ptr,
            req.pitch.asArgument.ptr,
          );

          if (retVal != 0) sendPort.send(Error('Failed to run TTS', req));
          if (retVal != 0) break;

          sendPort.send(TTSGenerationStart(start: true, req: req));

        // 🟥 getCurrentTTSGlobalTokens
        case GetCurrentTTSGlobalTokens _:
          final ttsGlobalTokensPtr = rwkvMobile.rwkvmobile_runtime_get_tts_global_tokens_output(runtime);
          final ttsGlobalTokensList = ttsGlobalTokensPtr.cast<Int32>().asTypedList(32).toList();
          sendPort.send({'ttsGlobalTokens': ttsGlobalTokensList});

        // 🟥 getTTSStreamingBuffer
        case GetTTSStreamingBuffer req:
          final generating = rwkvMobile.rwkvmobile_runtime_is_generating(runtime, req.modelID) == 1;
          final currentLength = rwkvMobile.rwkvmobile_runtime_get_tts_streaming_buffer_length(runtime);
          if (currentLength != ttsStreamingBufferList.length) {
            final ttsStreamingBuffer = rwkvMobile.rwkvmobile_runtime_get_tts_streaming_buffer(runtime);
            ttsStreamingBufferListDouble = ttsStreamingBuffer.samples.asTypedList(ttsStreamingBuffer.length).toList();
            ttsStreamingBufferList = ttsStreamingBufferListDouble.map((e) {
              return (e * 32768.0).toInt();
            }).toList();
            rwkvMobile.rwkvmobile_runtime_free_tts_streaming_buffer(ttsStreamingBuffer);
            sendPort.send(
              TTSStreamingBuffer(
                generating: generating,
                ttsStreamingBuffer: ttsStreamingBufferList,
                ttsStreamingBufferLength: ttsStreamingBufferList.length,
                rawFloatList: ttsStreamingBufferListDouble,
                req: req,
              ),
            );
          }

        // 🟥 dumpLog
        case DumpLog req:
          final log = rwkvMobile.rwkvmobile_dump_log();
          sendPort.send(RuntimeLog(runtimeLog: readRuntimeLog(log), req: req));

        // 🟥 dumpStateInfo
        case DumpStateInfo req:
          final stateInfo = rwkvMobile.rwkvmobile_get_state_cache_info(runtime, req.modelID);
          sendPort.send(StateInfo(stateInfo: stateInfo.cast<Utf8>().toDartString(), req: req));
          rwkvMobile.rwkvmobile_free_state_cache_info(stateInfo);

        // 🟥 saveRuntimeStateByHistory
        case SaveRuntimeStateByHistory req:
          for (var i = 0; i < req.messages.length; i++) {
            inputsPtr[i] = req.messages[i].ptr;
          }
          final numInputs = req.messages.length;
          final stateSavePathPtr = req.stateSavePath.ptr;
          final retVal = rwkvMobile.rwkvmobile_runtime_save_history_to_state(runtime, req.modelID, inputsPtr, numInputs, stateSavePathPtr);
          if (retVal != 0) sendPort.send(Error('Failed to save runtime state by history', req, retVal));

        // 🟥 loadRuntimeStateToMemory
        case LoadRuntimeStateToMemory req:
          final stateLoadPathPtr = req.stateLoadPath.ptr;
          final retVal = rwkvMobile.rwkvmobile_runtime_load_history_state_to_memory(runtime, req.modelID, stateLoadPathPtr);
          if (retVal != 0) sendPort.send(Error('Failed to load runtime state to memory', req, retVal));

        case SetSamplerAndPenaltyParams req:
          final samplerParams = Struct.create<sampler_params>();
          final penaltyParams = Struct.create<penalty_params>();

          for (var i = 0; i < req.temperatures.length; i++) {
            samplerParams.temperature = req.temperatures[i].toDouble();
            samplerParams.top_k = req.topKs[i].toInt();
            samplerParams.top_p = req.topPs[i].toDouble();

            penaltyParams.presence_penalty = req.presencePenalties[i].toDouble();
            penaltyParams.frequency_penalty = req.frequencyPenalties[i].toDouble();
            penaltyParams.penalty_decay = req.penaltyDecays[i].toDouble();

            rwkvMobile.rwkvmobile_runtime_set_sampler_params_on_batch_slot(runtime, req.modelID, i, samplerParams);
            rwkvMobile.rwkvmobile_runtime_set_penalty_params_on_batch_slot(runtime, req.modelID, i, penaltyParams);
          }

        case GetSamplerAndPenaltyParams req:
          final List<double> temperatures = [];
          final List<double> topKs = [];
          final List<double> topPs = [];
          final List<double> presencePenalties = [];
          final List<double> frequencyPenalties = [];
          final List<double> penaltyDecays = [];

          for (var i = 0; i < req.batchSize; i++) {
            final samplerParams = rwkvMobile.rwkvmobile_runtime_get_sampler_params_on_batch_slot(runtime, req.modelID, i);
            final penaltyParams = rwkvMobile.rwkvmobile_runtime_get_penalty_params_on_batch_slot(runtime, req.modelID, i);
            temperatures.add(samplerParams.temperature);
            topKs.add(samplerParams.top_k.toDouble());
            topPs.add(samplerParams.top_p);
            presencePenalties.add(penaltyParams.presence_penalty);
            frequencyPenalties.add(penaltyParams.frequency_penalty);
            penaltyDecays.add(penaltyParams.penalty_decay);
          }

          sendPort.send(
            SamplerAndPenaltyParams(
              temperatures: temperatures,
              topKs: topKs,
              topPs: topPs,
              presencePenalties: presencePenalties,
              frequencyPenalties: frequencyPenalties,
              penaltyDecays: penaltyDecays,
              req: req,
            ),
          );
      }
    }

    for (var i = 0; i < maxBatchSize; i++) {
      if (inputsBatchPtr[i] != nullptr) {
        malloc.free(inputsBatchPtr[i]);
      }
    }
    malloc.free(inputsPtr);
    malloc.free(inputsBatchPtr);
    malloc.free(numInputsBatchPtr);
    malloc.free(forceLangsBatchPtr);
    malloc.free(inputsBatchPtrCompletionAsync);
  }
}
