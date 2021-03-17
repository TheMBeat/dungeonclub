import 'dart:convert';
import 'dart:io';

import 'package:dnd_interactive/actions.dart' as a;
import 'package:dnd_interactive/comms.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'data.dart';
import 'server.dart';

final connections = <Connection>[];

void onConnect(WebSocketChannel ws) {
  print('New connection!');
  connections.add(Connection(ws));
}

class Connection extends Socket {
  final WebSocketChannel ws;
  final Stream broadcastStream;
  Game _game;

  Scene scene;

  Account _account;
  Account get account => _account;

  Connection(this.ws) : broadcastStream = ws.stream.asBroadcastStream() {
    listen(
      onDone: () {
        print('Lost connection (${ws.closeCode})');
        _game?.connect(this, false);
        connections.remove(this);
      },
      onError: (err) {
        print('ws error');
        print(err);
        print(ws.closeCode);
        print(ws.closeReason);
      },
    );
  }

  @override
  Stream get messageStream => broadcastStream;

  @override
  Future<void> send(data) async => ws.sink.add(data);

  @override
  Future handleAction(String action, [Map<String, dynamic> params]) async {
    switch (action) {
      case 'manualSave': // don't know about the safety of this one, chief
        return data.manualSave();

      case a.ACCOUNT_CREATE:
        var email = params['email'];
        if (data.getAccount(email) != null) {
          return false;
        }
        _account = Account(email, params['password']);
        data.accounts.add(_account);
        return _account.toSnippet();

      case a.ACCOUNT_LOGIN:
        return login(params['email'], params['password']);

      case a.GAME_CREATE_NEW:
        if (account == null) return false;

        _game = Game(account, params['name']);
        scene = _game.playingScene;
        data.games.add(_game);
        account.enteredGames.add(_game);
        return _game.toSessionSnippet(this);

      case a.GAME_EDIT:
        if (account == null) return false;

        var gameId = params['id'];
        var game = account.ownedGames.firstWhere(
            (g) => g.id == gameId && g.online == 0,
            orElse: () => null);
        if (game == null) return 'Access denied!';

        var data = params['data'];
        if (data != null) {
          // User wants to save changes.
          return game.applyChanges(data);
        }

        return game.toSessionSnippet(this);

      case a.GAME_DELETE:
        if (account == null) return false;

        var gameId = params['id'];
        var game = account.ownedGames
            .firstWhere((g) => g.id == gameId, orElse: () => null);
        if (game == null) return 'Access denied!';

        await game.delete();

        return true;

      case a.GAME_JOIN:
        var id = params['id'];
        var game = data.games.firstWhere((g) => g.id == id, orElse: () => null);
        if (game != null) {
          int id;
          if (game.owner != account) {
            if (!game.gmOnline) return 'GM is not online!';

            id = await game.gm.request(a.GAME_JOIN_REQUEST);
            if (id == null) return 'Access denied!';
            game.assignPC(id, this);
          }
          _game = game..connect(this, true);
          scene = game.playingScene;
          return game.toSessionSnippet(this, id);
        }
        return 'Game not found!';

      case a.GAME_MOVABLE_CREATE:
        if (scene != null) {
          var m = scene.addMovable(params);
          notifyOthers(action, {
            'id': m.id,
            'x': m.x,
            'y': m.y,
            'img': m.img,
          });
          return m.id;
        }
        return null;

      case a.GAME_MOVABLE_MOVE:
        var m = scene?.getMovable(params['id']);
        if (m != null) {
          m
            ..x = params['x']
            ..y = params['y'];
        }
        return notifyOthers(action, params);

      case a.GAME_CHARACTER_UPLOAD:
        return await _uploadGameImageJson(params);

      case a.GAME_SCENE_UPDATE:
        if (_game?.gm != this || scene == null) return;

        var grid = params['grid'];
        if (grid != null) {
          scene.applyGrid(grid);
          return notifyOthers(action, params);
        }

        var img = params['data'];
        if (img != null) {
          var result = await _uploadGameImageJson(params);
          if (result != null) {
            _game.notify(a.GAME_SCENE_UPDATE, {}, exclude: this);
            return result;
          }
        }
        return null;

      case a.GAME_SCENE_GET:
        var sceneId = params['id'];
        var s = _game?.getScene(sceneId);
        if (s == null) return null;

        scene = s;
        return s.toJson();

      case a.GAME_SCENE_PLAY:
        var sceneId = params['id'];
        var scene = _game?.getScene(sceneId);
        if (scene == null) return null;

        _game.playScene(sceneId);
        var result = scene.toJson();
        _game.notify(action, {'id': sceneId, ...result},
            exclude: this, allScenes: true);
        return result;

      case a.GAME_SCENE_ADD:
        var id = _game.sceneCount;
        var s = _game?.addScene();
        if (s == null) return null;

        await _uploadGameImage(
          type: a.IMAGE_TYPE_SCENE,
          id: id,
          base64: params['data'],
        );
        scene = s;
        return s.toJson();

      case a.GAME_SCENE_REMOVE:
        int id = params['id'];
        if (_game == null ||
            _account == null ||
            _game.owner != _account ||
            id == null) return;

        var doNotifyOthers = _game.playingSceneId == id;

        var removed = await _game.removeScene(id);
        if (!removed) return;

        var result = _game.playingScene.toJson();
        if (doNotifyOthers) {
          _game.notify(action, {'id': _game.playingSceneId, ...result},
              exclude: this, allScenes: true);
        }
        return result;

      case a.GAME_ROLL_DICE:
        List<dynamic> dice = params['dice'];
        if (dice == null || _game == null) return;

        var results = {
          'results': dice
              .map((e) => {
                    'sides': e,
                    'result': data.rng.nextInt(e) + 1,
                  })
              .toList()
        };

        _game.notify(action, results, exclude: this, allScenes: true);
        return results;
    }
  }

  Future<String> _uploadGameImage({
    String base64,
    String type,
    int id,
    String gameId,
  }) async {
    if (base64 == null || type == null || id == null) return 'Missing info';

    var game = gameId != null
        ? account.ownedGames
            .firstWhere((g) => g.id == gameId, orElse: () => null)
        : _game;

    if (game != null) {
      var file = await (await game.getFile('$type$id.png')).create();

      await file.writeAsBytes(base64Decode(base64));
      return '$address/${file.path.replaceAll('\\', '/')}';
    }
    return 'Missing game info';
  }

  Future<String> _uploadGameImageJson(Map<String, dynamic> json) {
    return _uploadGameImage(
      base64: json['data'],
      type: json['type'],
      id: json['id'],
      gameId: json['gameId'],
    );
  }

  void notifyOthers(String action, [Map<String, dynamic> params]) {
    _game?.notify(action, params, exclude: this);
  }

  dynamic login(String email, String password) {
    var acc = data.getAccount(email);
    if (acc == null) {
      return false;
    }
    _account = acc;
    print('Connection logged in with account ' + acc.encryptedEmail.hash);
    return acc.toSnippet();
  }
}
