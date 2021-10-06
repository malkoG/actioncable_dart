import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';

import 'channel_id.dart';

typedef _OnConnectedFunction = void Function();
typedef _OnConnectionLostFunction = void Function();
typedef _OnCannotConnectFunction = void Function();
typedef _OnChannelSubscribedFunction = void Function();
typedef _OnChannelDisconnectedFunction = void Function();
typedef _OnChannelMessageFunction = void Function(Map message);

class ActionCable {
  DateTime? _lastPing;
  late Timer _timer;
  late IOWebSocketChannel _socketChannel;
  late StreamSubscription _listener;
  late String connectionUrl;
  late Map<String, String> connectionHeaders;
  _OnConnectedFunction? onConnected;
  _OnCannotConnectFunction? onCannotConnect;
  _OnConnectionLostFunction? onConnectionLost;
  Map<String, _OnChannelSubscribedFunction?> _onChannelSubscribedCallbacks = {};
  Map<String, _OnChannelDisconnectedFunction?> _onChannelDisconnectedCallbacks =
      {};
  Map<String, _OnChannelMessageFunction?> _onChannelMessageCallbacks = {};

  bool retryUnlimited;
  SplayTreeSet<String> subscriptions = SplayTreeSet<String>();

  ActionCable.Connect(
    String url, {
    Map<String, String> headers: const {},
    this.onConnected,
    this.onConnectionLost,
    this.onCannotConnect,
    this.retryUnlimited = false,
  }) {
    this.connectionUrl = url;
    this.connectionHeaders = headers;

    this._setupConnection();
  }

  void disconnect() {
    this.subscriptions.clear();

    _timer.cancel();
    _socketChannel.sink.close();
    _listener.cancel();
  }

  void _setupConnection() {
    try {
      // rails gets a ping every 3 seconds
      _socketChannel = IOWebSocketChannel.connect(this.connectionUrl,
          headers: this.connectionHeaders, pingInterval: Duration(seconds: 3));
      _listener = _socketChannel.stream.listen(_onData, onError: (_) {
        if (!this.retryUnlimited)
          this.disconnect(); // close a socket and the timer
        else {}
        if (this.onCannotConnect != null) this.onCannotConnect!();
      });
    } catch (error) {
      print("=== Connection Refused! ===");
      print(error);
    }

    _timer = Timer.periodic(const Duration(seconds: 3), healthCheck);
  }

  void _reconnect() {
    try {
      this._setupConnection();

      for (var channelId in subscriptions) {
        _send({'identifier': channelId, 'command': 'subscribe'});
      }
    } catch (error) {
      print(error);
    }
  }

  // check if there is no ping for 3 seconds and signal a [onConnectionLost] if
  // there is no ping for more than 6 seconds
  void healthCheck(_) {
    if (_lastPing == null) {
      return;
    }
    if (DateTime.now().difference(_lastPing!) > Duration(seconds: 6)) {
      if (retryUnlimited) {
        _timer.cancel();
        this._reconnect();
      } else {
        this.disconnect();
      }
      if (this.onConnectionLost != null) this.onConnectionLost!();
    }
  }

  // channelName being 'Chat' will be considered as 'ChatChannel',
  // 'Chat', { id: 1 } => { channel: 'ChatChannel', id: 1 }
  void subscribe(String channelName,
      {Map? channelParams,
      _OnChannelSubscribedFunction? onSubscribed,
      _OnChannelDisconnectedFunction? onDisconnected,
      _OnChannelMessageFunction? onMessage}) {
    final channelId = encodeChannelId(channelName, channelParams);

    _onChannelSubscribedCallbacks[channelId] = onSubscribed;
    _onChannelDisconnectedCallbacks[channelId] = onDisconnected;
    _onChannelMessageCallbacks[channelId] = onMessage;

    if (retryUnlimited) subscriptions.add(channelId);

    _send({'identifier': channelId, 'command': 'subscribe'});
  }

  void unsubscribe(String channelName, {Map? channelParams}) {
    final channelId = encodeChannelId(channelName, channelParams);

    _onChannelSubscribedCallbacks[channelId] = null;
    _onChannelDisconnectedCallbacks[channelId] = null;
    _onChannelMessageCallbacks[channelId] = null;

    if (retryUnlimited) subscriptions.remove(channelId);

    _socketChannel.sink
        .add(jsonEncode({'identifier': channelId, 'command': 'unsubscribe'}));
  }

  void performAction(String channelName,
      {String? action, Map? channelParams, Map? actionParams}) {
    final channelId = encodeChannelId(channelName, channelParams);

    actionParams ??= {};
    actionParams['action'] = action;

    _send({
      'identifier': channelId,
      'command': 'message',
      'data': jsonEncode(actionParams)
    });
  }

  void _onData(dynamic payload) {
    payload = jsonDecode(payload);

    if (payload['type'] != null) {
      _handleProtocolMessage(payload);
    } else {
      _handleDataMessage(payload);
    }
  }

  void _handleProtocolMessage(Map payload) {
    switch (payload['type']) {
      case 'ping':
        // rails sends epoch as seconds not miliseconds
        _lastPing =
            DateTime.fromMillisecondsSinceEpoch(payload['message'] * 1000);
        break;
      case 'welcome':
        if (onConnected != null) {
          onConnected!();
        }
        break;
      case 'disconnect':
        final channelId = parseChannelId(payload['identifier']);
        final onDisconnected = _onChannelDisconnectedCallbacks[channelId];
        if (onDisconnected != null) {
          onDisconnected();
        }
        break;
      case 'confirm_subscription':
        final channelId = parseChannelId(payload['identifier']);
        final onSubscribed = _onChannelSubscribedCallbacks[channelId];
        if (onSubscribed != null) {
          onSubscribed();
        }
        break;
      case 'reject_subscription':
        // throw 'Unimplemented';
        break;
      default:
        throw 'InvalidMessage';
    }
  }

  void _handleDataMessage(Map payload) {
    final channelId = parseChannelId(payload['identifier']);
    final onMessage = _onChannelMessageCallbacks[channelId];
    if (onMessage != null) {
      onMessage(payload['message']);
    }
  }

  void _send(Map payload) {
    _socketChannel.sink.add(jsonEncode(payload));
  }
}
