import 'dart:html';
import 'dart:math';

import 'package:dnd_interactive/actions.dart';

import '../../main.dart';
import '../communication.dart';
import '../panels/panel_overlay.dart';
import 'log.dart';
import 'movable.dart';
import 'prefab.dart';

HtmlElement get initiativeBar => querySelector('#initiativeBar');
HtmlElement get charContainer => initiativeBar.querySelector('.roster');

class InitiativeTracker {
  bool _trackerActive = false;
  ButtonElement get callRollsButton => querySelector('#initiativeTracker');
  InputElement get initiativeModInput => querySelector('#initiativeMod');
  ButtonElement get userRollButton => querySelector('#initiativeRoll');
  HtmlElement get panel => querySelector('#initiativePanel');

  InitiativeSummary summary;

  set showBar(bool v) => initiativeBar.classes.toggle('hidden', !v);

  void init() {
    callRollsButton.onClick.listen((event) {
      _trackerActive = callRollsButton.classes.toggle('active');

      if (_trackerActive) {
        rollForInitiative();
      } else {
        outOfCombat();
        socket.sendAction(GAME_CLEAR_INITIATIVE);
      }
    });

    userRollButton.onClick.listen((event) {
      randomResultInChat();
    });
  }

  void rollForInitiative() {
    resetBar();
    socket.sendAction(GAME_ROLL_INITIATIVE);
    // for (var i = 0; i < 15; i++) {
    //   onRollAdd(i % 2, Random().nextInt(20));
    // }
  }

  void randomResultInChat() {
    var value = initiativeModInput.valueAsNumber;
    print(value);
    if (!value.isFinite) return;

    var mod = value.toInt();
    var r = Random().nextInt(20) + 1;
    var total = r + mod;

    gameLog('''You rolled $r with an initiative modifier of
          $mod for a total of $total for initiative.''', mine: true);

    panel.classes.remove('show');
    overlayVisible = false;

    var pc = user.session.charId;

    onRollAdd(pc, total);
    socket.sendAction(GAME_ADD_INITIATIVE, {'id': pc, 'total': total});
  }

  void onRollAdd(int pc, int total) {
    var movable = user.session.board.movables.firstWhere((m) {
      var pref = m.prefab;
      if (pref is CharacterPrefab) {
        return pref.character.id == pc;
      }
      return false;
    });

    summary.registerRoll(movable, total);
  }

  void showRollerPanel() {
    resetBar();
    panel.classes.add('show');
    overlayVisible = true;
  }

  void resetBar() {
    summary = InitiativeSummary();
    charContainer.children.clear();
    showBar = true;
  }

  void addToInBar(Map<String, dynamic> json) {
    int id = json['id'];
    int total = json['total'];
    onRollAdd(id, total);
  }

  void outOfCombat() {
    showBar = false;
    if (panel.classes.remove('show')) overlayVisible = false;
  }
}

class InitiativeSummary {
  List<int> totals = [];

  void registerRoll(Movable movable, int total) {
    var index = totals.lastIndexWhere((other) => total <= other) + 1;

    totals.insert(index, total);
    print(totals);

    var elem = DivElement()
      ..className = 'char'
      ..append(ImageElement(src: movable.prefab.img(cacheBreak: false)))
      ..append(SpanElement()..text = movable.prefab.name);

    charContainer.children.insert(index, elem);
  }
}