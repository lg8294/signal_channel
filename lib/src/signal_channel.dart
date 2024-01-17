import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:hwkj_api_core/hwkj_api_core.dart';
import 'package:logger/logger.dart';
import 'package:logging/logging.dart' as logging;
import 'package:signal_channel/src/error.dart';
import 'package:signal_channel/src/utils.dart';
import 'package:signalr_netcore/signalr_client.dart';

import 'constants.dart';

typedef SignalInterceptorHook = void Function(String requestId);

class SignalChannelHooks {
  SignalInterceptorHook? didAddRequest;
  SignalInterceptorHook? didReceiveResponse;
  SignalInterceptorHook? didRemoveRequest;
  SignalInterceptorHook? didReceiveResponseWithoutRequest;
}

enum SignalChannelState {
  Disconnected,

  Connected,

  Reconnecting,
}

class SignalChannel {
  static SignalChannel? globalSignalChannel;
  static Logger? logger;

  final String _url;
  final AccessTokenFactory _accessTokenFactory;
  HubConnection? _hubConnection;

  /// 意外断开后是否需要重连
  late bool _needReconnect;

  late Map<String, List<MethodInvocationFunc>> _methods;

  /// 待处理请求集合
  late Map<String, Completer<APIResult>> _requestMap;

  late ValueNotifier<SignalChannelState> stateNotifier;

  SignalChannelHooks? hooks;

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
          .configureLogging(logging.Logger('$this'))
          .build();

      _hubConnection!.on(kRequestResponseChannelKey, _handleRequestResponse);
      _hubConnection!.on(
          kCloseConnectionFromServerSide, _handleConnectionCloseFromServerSide);
      _hubConnection!.onclose(_connectionClose);

      _methods.forEach((methodName, methodList) {
        methodList.forEach((newMethod) {
          _hubConnection!.on(methodName, newMethod);
        });
      });

      _needReconnect = true;
      await _hubConnection!.start();
      stateNotifier.value = SignalChannelState.Connected;
    } catch (e, trace) {
      logger?.e(SignalRChannelError('start 异常'), e, trace);
      stateNotifier.value = SignalChannelState.Disconnected;
      rethrow;
    }
  }

  Future stop({bool autoReconnect = false}) async {
    _needReconnect = autoReconnect;

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

  void _connectionClose({Exception? error}) {
    logger?.v('$runtimeType 链接断开', error);
    if (_needReconnect)
      reconnect();
    else
      stateNotifier.value = SignalChannelState.Disconnected;
  }

  void cleanMethods() {
    _methods.clear();
  }

  ///  Registers a handler that will be invoked when the hub method with the specified method name is invoked.
  ///
  /// methodName: The name of the hub method to define.
  /// newMethod: The handler that will be raised when the hub method is invoked.
  ///
  void on(String methodName, MethodInvocationFunc newMethod) {
    if (isEmpty(methodName)) {
      return;
    }

    methodName = methodName.toLowerCase();
    if (_methods[methodName] == null) {
      _methods[methodName] = [];
    }

    // Preventing adding the same handler multiple times.
    if (_methods[methodName]!.indexOf(newMethod) != -1) {
      return;
    }

    _methods[methodName]!.add(newMethod);
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
  void off(String methodName, {MethodInvocationFunc? method}) {
    if (isEmpty(methodName)) {
      return;
    }

    methodName = methodName.toLowerCase();
    final List<void Function(List<Object>)>? handlers = _methods[methodName];
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
    logger?.v('添加待处理请求 $requestId');
    _requestMap[requestId] = completer;
    hooks?.didAddRequest?.call(requestId);
  }

  /// 移除请求
  void removeRequest(String requestId) {
    logger?.v('移除待处理请求 $requestId');
    _requestMap.remove(requestId);
    hooks?.didRemoveRequest?.call(requestId);
  }

  /// 处理请求的响应结果
  void _handleRequestResponse(arguments) {
    logger?.v('处理响应 $arguments');
    Map data = arguments.first;
    final String? requestId = data['SignalrType'];
    if (_requestMap.containsKey(requestId)) {
      hooks?.didReceiveResponse?.call(requestId!);
      final complete = _requestMap.remove(requestId)!;
      if (!complete.isCompleted) complete.complete(APIResult.success(data));
    } else {
      hooks?.didReceiveResponseWithoutRequest?.call(requestId!);
    }
  }

  HubConnectionState? get state => _hubConnection?.state;

  void _handleConnectionCloseFromServerSide(List<Object?>? arguments) {
    logger?.i('服务端请求关闭连接 $arguments');
    stop();
  }

  /// Invokes a hub method on the server using the specified name and arguments. Does not wait for a response from the receiver.
  ///
  /// The Promise returned by this method resolves when the client has sent the invocation to the server. The server may still
  /// be processing the invocation.
  ///
  /// methodName: The name of the server method to invoke.
  /// args: The arguments used to invoke the server method.
  /// Returns a Promise that resolves when the invocation has been successfully sent, or rejects with an error.
  ///
  Future<void> send(String methodName, List<Object> args) {
    return _hubConnection!.send(methodName, args: args);
  }

  /// Invokes a hub method on the server using the specified name and arguments.
  ///
  /// The Future returned by this method resolves when the server indicates it has finished invoking the method. When the Future
  /// resolves, the server has finished invoking the method. If the server method returns a result, it is produced as the result of
  /// resolving the Promise.
  ///
  /// methodName: The name of the server method to invoke.
  /// args: The arguments used to invoke the server method.
  /// Returns a Future that resolves with the result of the server method (if any), or rejects with an error.
  ///

  Future<Object?> invoke(String methodName, {List<Object>? args}) {
    return _hubConnection!.invoke(methodName, args: args);
  }
}
