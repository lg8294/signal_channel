import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hwkj_api_core/hwkj_api_core.dart';
import 'package:uuid/uuid.dart';

import 'constants.dart';
import 'signal_channel.dart';

/// 默认处理超时
const _defaultTimeout = Duration(seconds: 60);

class SignalInterceptor extends Interceptor {
  /// 处理超时
  Duration timeout;
  @override
  Future onRequest(RequestOptions options) async {
    options.headers.addAll({
      HeaderSignalRCallbackKey: kRequestResponseChannelKey,
      HeaderSignalRTypeKey: Uuid().v4(),
    });

    return options;
  }

  @override
  Future onResponse(Response response) async {
    if (response.statusCode == 200) {
      final r = ApiClient.globalParseResponseData(response);
      if (r.type == 202) {
        final r1 =
            await _handle202(response.request.headers[HeaderSignalRTypeKey]);

        if (r1.success) {
          // 成功后，r1.data 中包含 Code,Content,Data字段
          response.data = r1.data;
        } else {
          final data = AjaxResultEntity()
            ..type = -1
            ..content = r1.msg
            ..data = r1.data;
          response.data = data.toJson();
        }
      }
    }
    return response;
  }

  /// 处理202响应
  Future<APIResult> _handle202(String requestId) async {
    final resultCompleter = Completer<APIResult>();

    if (SignalChannel.globalSignalChannel == null)
      resultCompleter.complete(APIResult.failure('未建立 signalR 通道', null));

    SignalChannel.globalSignalChannel?.addRequest(requestId, resultCompleter);

    return resultCompleter.future.timeout(timeout ?? _defaultTimeout,
        onTimeout: () => APIResult.failure('请求超时', null));
  }
}
