import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:hwkj_api_core/hwkj_api_core.dart';
import 'package:lg_signalr_client/lg_signalr_client.dart';
import 'package:logger/logger.dart';
import 'package:logging/logging.dart' as log;
import 'package:signal_channel/src/utils.dart';

import 'constants.dart';

typedef SignalInterceptorHook = void Function(String requestId);

class SignalChannelHooks {
  SignalInterceptorHook didAddRequest;
  SignalInterceptorHook didReceiveResponse;
  SignalInterceptorHook didRemoveRequest;
  SignalInterceptorHook didReceiveResponseWithoutRequest;
}

enum SignalChannelState {
  Disconnected,

  Connected,

  Reconnecting,
}

class SignalChannel {
  static SignalChannel globalSignalChannel;

  final String _url;
  final AccessTokenFactory _accessTokenFactory;
  Logger _logger;
  HubConnection _hubConnection;

  /// 意外断开后是否需要重连
  bool _needReconnect;

  Map<String, List<MethodInvocationFunc>> _methods;

  /// 待处理请求集合
  Map<String, Completer<APIResult>> _requestMap;

  ValueNotifier<SignalChannelState> stateNotifier;

  SignalChannelHooks hooks;

  SignalChannel(String url, AccessTokenFactory accessTokenFactory)
      : this._url = url,
        this._accessTokenFactory = accessTokenFactory {
    _methods = {};
    _requestMap = {};
    stateNotifier = ValueNotifier(SignalChannelState.Disconnected);
  }

  void dispose() {
    stateNotifier.dispose();
  }

  /// 设置打印日志
  SignalChannel configWithLogger(Logger logger) {
    _logger = logger;
    return this;
  }

  Future start() async {
    try {
      if (_hubConnection?.state == HubConnectionState.Connected) return;

      _hubConnection = HubConnectionBuilder()
          .withUrl(_url,
              options: HttpConnectionOptions(
                transport: HttpTransportType.WebSockets,
                accessTokenFactory: _accessTokenFactory,
                skipNegotiation: true,
              ))
          .configureLogging(log.Logger('$this'))
          .build();

      _hubConnection.on(kRequestResponseChannelKey, _handleRequestResponse);
      _hubConnection.onClose(_connectionClose);

      _methods?.forEach((methodName, methodList) {
        methodList.forEach((newMethod) {
          _hubConnection.on(methodName, newMethod);
        });
      });

      _needReconnect = true;
      await _hubConnection.start();
      stateNotifier.value = SignalChannelState.Connected;
    } catch (e, trace) {
      _logger?.e('signal_channel start', e, trace);
      stateNotifier.value = SignalChannelState.Disconnected;
      throw e;
    }
  }

  Future stop({bool autoReconnect = false}) async {
    _needReconnect = autoReconnect ?? false;

    final preHub = _hubConnection;
    _hubConnection = null;

    _requestMap.values
        .where((element) => !element.isCompleted)
        .forEach((element) {
      element.complete(APIResult.failure('连接断开', null));
    });
    _requestMap.clear();

    if (preHub?.state == HubConnectionState.Connected) await preHub?.stop();
    stateNotifier.value = SignalChannelState.Disconnected;
  }

  Future reconnect() async {
    if (_hubConnection?.state == HubConnectionState.Connected) return;
    stateNotifier.value = SignalChannelState.Reconnecting;
    return start();
  }

  void _connectionClose(Exception error) {
    _logger?.e('', error);
    if (_needReconnect)
      reconnect();
    else
      stateNotifier.value = SignalChannelState.Disconnected;
  }

  // void on(String methodName, MethodInvocationFunc newMethod) {
  //   if (_hubConnection == null) throw SignalRChannelError('先执行 start');
  //   _hubConnection.on(methodName, newMethod);
  // }
  //
  // void off(String methodName, {MethodInvocationFunc method}) {
  //   if (_hubConnection == null) throw SignalRChannelError('先执行 start');
  //   _hubConnection.off(methodName, method: method);
  // }

  void cleanMethods() {
    _methods.clear();
  }

  ///  Registers a handler that will be invoked when the hub method with the specified method name is invoked.
  ///
  /// methodName: The name of the hub method to define.
  /// newMethod: The handler that will be raised when the hub method is invoked.
  ///
  void on(String methodName, MethodInvocationFunc newMethod) {
    if (isStringEmpty(methodName) || newMethod == null) {
      return;
    }

    methodName = methodName.toLowerCase();
    if (_methods[methodName] == null) {
      _methods[methodName] = [];
    }

    // Preventing adding the same handler multiple times.
    if (_methods[methodName].indexOf(newMethod) != -1) {
      return;
    }

    _methods[methodName].add(newMethod);
    _hubConnection?.on(methodName, newMethod);
  }

  /// Removes the specified handler for the specified hub method.
  ///
  /// You must pass the exact same Function instance as was previously passed to HubConnection.on. Passing a different instance (even if the function
  /// body is the same) will not remove the handler.
  ///
  /// methodName: The name of the method to remove handlers for.
  /// method: The handler to remove. This must be the same Function instance as the one passed to {@link @aspnet/signalr.HubConnection.on}.
  /// If the method handler is omitted, all handlers for that method will be removed.
  ///
  void off(String methodName, {MethodInvocationFunc method}) {
    if (isStringEmpty(methodName)) {
      return;
    }

    methodName = methodName.toLowerCase();
    final handlers = _methods[methodName];
    if (handlers == null) {
      return;
    }

    if (method != null) {
      final removeIdx = handlers.indexOf(method);
      if (removeIdx != -1) {
        handlers.removeAt(removeIdx);
        if (handlers.length == 0) {
          _methods.remove(methodName);
        }
      }
    } else {
      _methods.remove(methodName);
    }
    _hubConnection?.off(methodName, method: method);
  }

  /// 添加待处理的请求
  void addRequest(String requestId, Completer<APIResult> completer) {
    _logger?.v('添加待处理请求 $requestId');
    _requestMap[requestId] = completer;
    hooks?.didAddRequest?.call(requestId);
  }

  /// 移除请求
  void removeRequest(String requestId) {
    _logger?.v('移除待处理请求 $requestId');
    _requestMap.remove(requestId);
    hooks?.didRemoveRequest?.call(requestId);
  }

  /// 处理请求的响应结果
  void _handleRequestResponse(arguments) {
    _logger?.v('处理响应 $arguments');
    Map data = arguments.first;
    final String requestId = data['SignalrType'];
    if (_requestMap.containsKey(requestId)) {
      hooks?.didReceiveResponse?.call(requestId);
      final complete = _requestMap.remove(requestId);
      if (!complete.isCompleted) complete.complete(APIResult.success(data));
    } else {
      hooks?.didReceiveResponseWithoutRequest?.call(requestId);
    }
  }

  HubConnectionState get state => _hubConnection?.state;
}
