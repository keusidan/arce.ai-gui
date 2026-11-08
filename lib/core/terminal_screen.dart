import 'dart:convert';

/// A small terminal: what a program wrote to its pseudo terminal, as the screen a person would see,
/// in text. A model cannot read raw terminal output (colour codes, a prompt redrawn with `\r`, a menu
/// that moves the cursor); it can read the screen those bytes make.
///
/// It understands what interactive command-line programs actually use: printing with `\r \n \b \t`,
/// moving the cursor (`CSI A B C D E F G H f d`), erasing (`J K X`), inserting and deleting lines and
/// characters (`L M P @`), a scroll region (`r`), saving the cursor, reverse index. Colours and styles
/// (`m`), the window title and every other sequence are read and dropped. The alternate screen of a full
/// screen program is taken as the one screen (its picture is what the model should read).
///
/// Lines that scroll off the top are kept ([scrollback], at most [maxScrollback]) and handed out once
/// by [takeScrolled], so a program that prints a lot is read from where the last read stopped.
class TerminalScreen {
  TerminalScreen({this.cols = 120, this.rows = 40, this.maxScrollback = 500})
      : assert(cols > 0 && rows > 0),
        _grid = List.generate(rows, (_) => List.filled(cols, 32, growable: true)),
        _bottom = rows - 1;

  final int cols;
  final int rows;
  final int maxScrollback;

  final List<List<int>> _grid;
  final List<String> _scrollback = [];
  int _unread = 0;

  var _row = 0;
  var _col = 0;
  var _top = 0;
  int _bottom;
  var _savedRow = 0;
  var _savedCol = 0;

  /// The cursor is at the right edge and the next printable character goes to the next line.
  var _wrapPending = false;

  // the parser: bytes -> text (a character cut in two between two chunks waits for the rest)
  late final Sink<List<int>> _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_TextSink(_write));
  var _pending = '';

  List<int> _blank() => List.filled(cols, 32, growable: true);

  int get cursorRow => _row;
  int get cursorCol => _col;

  /// Feeds what the program wrote.
  void feed(List<int> bytes) => _decoder.add(bytes);

  /// The screen, one line per row, trailing blanks cut, empty rows at the bottom dropped.
  String text() {
    final lines = [for (final row in _grid) String.fromCharCodes(row).trimRight()];
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  /// All the lines that scrolled off and are kept.
  List<String> get scrollback => List.unmodifiable(_scrollback);

  /// The lines that scrolled off since the last call (what a reader has not seen yet), at most what is kept.
  List<String> takeScrolled() {
    final count = _unread.clamp(0, _scrollback.length);
    _unread = 0;
    return _scrollback.sublist(_scrollback.length - count);
  }

  // ------------------------------------------------------------------ parsing

  void _write(String chunk) {
    final text = _pending + chunk;
    _pending = '';
    final runes = text.runes.toList();
    var i = 0;
    while (i < runes.length) {
      final ch = runes[i];
      if (ch == 0x1b) {
        final used = _escape(runes, i);
        if (used < 0) {
          // a sequence that is not complete: wait for the rest (but not forever)
          if (runes.length - i < 256) {
            _pending = String.fromCharCodes(runes.sublist(i));
            return;
          }
          i++;
        } else {
          i += used;
        }
        continue;
      }
      _print(ch);
      i++;
    }
  }

  /// Handles the escape sequence at [at]; returns how many runes it took, or -1 when it is not complete yet.
  int _escape(List<int> r, int at) {
    if (at + 1 >= r.length) return -1;
    final next = r[at + 1];
    switch (next) {
      case 0x5b: // [  CSI
        var i = at + 2;
        final params = StringBuffer();
        while (i < r.length && r[i] >= 0x30 && r[i] <= 0x3f) {
          params.writeCharCode(r[i]);
          i++;
        }
        while (i < r.length && r[i] >= 0x20 && r[i] <= 0x2f) {
          i++; // intermediate bytes
        }
        if (i >= r.length) return -1;
        _csi(String.fromCharCode(r[i]), params.toString());
        return i - at + 1;
      case 0x5d: // ]  OSC: up to BEL or ESC \
        var i = at + 2;
        while (i < r.length) {
          if (r[i] == 0x07) return i - at + 1;
          if (r[i] == 0x1b) {
            if (i + 1 >= r.length) return -1;
            if (r[i + 1] == 0x5c) return i - at + 2;
          }
          i++;
        }
        return -1;
      case 0x28: // ( ) * +  charset designation: one more byte
      case 0x29:
      case 0x2a:
      case 0x2b:
        return at + 2 >= r.length ? -1 : 3;
      case 0x37: // 7 save cursor
        _savedRow = _row;
        _savedCol = _col;
        return 2;
      case 0x38: // 8 restore cursor
        _row = _savedRow.clamp(0, rows - 1);
        _col = _savedCol.clamp(0, cols - 1);
        _wrapPending = false;
        return 2;
      case 0x4d: // M reverse index
        if (_row == _top) {
          _scrollDown(1);
        } else if (_row > 0) {
          _row--;
        }
        return 2;
      case 0x44: // D index
        _lineFeed();
        return 2;
      case 0x45: // E next line
        _col = 0;
        _lineFeed();
        return 2;
      case 0x63: // c full reset
        _reset();
        return 2;
      default:
        return 2; // = > H ... : one byte, nothing to do
    }
  }

  void _csi(String final_, String raw) {
    final private = raw.startsWith('?') || raw.startsWith('>') || raw.startsWith('<') || raw.startsWith('=');
    final nums = [
      for (final part in raw.replaceAll(RegExp(r'^[?>=<]'), '').split(';')) int.tryParse(part),
    ];
    int p(int index, int fallback) => index < nums.length && nums[index] != null && nums[index]! > 0 ? nums[index]! : fallback;
    if (private) return; // modes (cursor shown, alternate screen, mouse ...): the picture is what counts
    switch (final_) {
      case 'A':
        _row = (_row - p(0, 1)).clamp(_top, rows - 1);
        _wrapPending = false;
      case 'B':
        _row = (_row + p(0, 1)).clamp(0, _bottom);
        _wrapPending = false;
      case 'C':
        _col = (_col + p(0, 1)).clamp(0, cols - 1);
        _wrapPending = false;
      case 'D':
        _col = (_col - p(0, 1)).clamp(0, cols - 1);
        _wrapPending = false;
      case 'E':
        _row = (_row + p(0, 1)).clamp(0, _bottom);
        _col = 0;
        _wrapPending = false;
      case 'F':
        _row = (_row - p(0, 1)).clamp(_top, rows - 1);
        _col = 0;
        _wrapPending = false;
      case 'G':
        _col = (p(0, 1) - 1).clamp(0, cols - 1);
        _wrapPending = false;
      case 'd':
        _row = (p(0, 1) - 1).clamp(0, rows - 1);
        _wrapPending = false;
      case 'H':
      case 'f':
        _row = (p(0, 1) - 1).clamp(0, rows - 1);
        _col = (p(1, 1) - 1).clamp(0, cols - 1);
        _wrapPending = false;
      case 'J':
        final mode = nums.isEmpty ? 0 : (nums[0] ?? 0);
        if (mode == 0) {
          _eraseLine(_row, from: _col);
          for (var r = _row + 1; r < rows; r++) {
            _eraseLine(r);
          }
        } else if (mode == 1) {
          for (var r = 0; r < _row; r++) {
            _eraseLine(r);
          }
          _eraseLine(_row, to: _col);
        } else {
          for (var r = 0; r < rows; r++) {
            _eraseLine(r);
          }
        }
      case 'K':
        final mode = nums.isEmpty ? 0 : (nums[0] ?? 0);
        if (mode == 0) {
          _eraseLine(_row, from: _col);
        } else if (mode == 1) {
          _eraseLine(_row, to: _col);
        } else {
          _eraseLine(_row);
        }
      case 'X':
        _eraseLine(_row, from: _col, to: _col + p(0, 1) - 1);
      case 'L':
        if (_row >= _top && _row <= _bottom) _insertLines(p(0, 1));
      case 'M':
        if (_row >= _top && _row <= _bottom) _deleteLines(p(0, 1));
      case 'P':
        final n = p(0, 1).clamp(0, cols - _col);
        final line = _grid[_row];
        line.removeRange(_col, _col + n);
        line.addAll(List.filled(n, 32, growable: true));
      case '@':
        final n = p(0, 1).clamp(0, cols - _col);
        final line = _grid[_row];
        line.insertAll(_col, List.filled(n, 32, growable: true));
        line.removeRange(cols, line.length);
      case 'S':
        _scrollUp(p(0, 1));
      case 'T':
        _scrollDown(p(0, 1));
      case 'r':
        final top = p(0, 1) - 1;
        final bottom = (nums.length > 1 && nums[1] != null && nums[1]! > 0 ? nums[1]! : rows) - 1;
        if (top >= 0 && bottom < rows && top < bottom) {
          _top = top;
          _bottom = bottom;
        } else {
          _top = 0;
          _bottom = rows - 1;
        }
        _row = 0;
        _col = 0;
        _wrapPending = false;
      case 's':
        _savedRow = _row;
        _savedCol = _col;
      case 'u':
        _row = _savedRow.clamp(0, rows - 1);
        _col = _savedCol.clamp(0, cols - 1);
        _wrapPending = false;
      default:
        break; // m (style), n, c, t, h, l ...: nothing to show
    }
  }

  // ------------------------------------------------------------------ printing

  void _print(int ch) {
    switch (ch) {
      case 0x0d:
        _col = 0;
        _wrapPending = false;
      case 0x0a:
      case 0x0b:
      case 0x0c:
        _lineFeed();
        // a terminal driver turns \n into \r\n; the program's own output did that already
      case 0x08:
        if (_col > 0) _col--;
        _wrapPending = false;
      case 0x09:
        _col = (((_col ~/ 8) + 1) * 8).clamp(0, cols - 1);
        _wrapPending = false;
      case 0x07:
      case 0x00:
      case 0x0e:
      case 0x0f:
        break;
      default:
        if (ch < 0x20 || ch == 0x7f) return;
        if (_wrapPending) {
          _col = 0;
          _lineFeed();
          _wrapPending = false;
        }
        _grid[_row][_col] = ch;
        if (_col == cols - 1) {
          _wrapPending = true;
        } else {
          _col++;
        }
    }
  }

  void _lineFeed() {
    if (_row == _bottom) {
      _scrollUp(1);
    } else if (_row < rows - 1) {
      _row++;
    }
  }

  void _scrollUp(int n) {
    for (var k = 0; k < n; k++) {
      final gone = _grid.removeAt(_top);
      if (_top == 0) {
        _scrollback.add(String.fromCharCodes(gone).trimRight());
        _unread++;
        if (_scrollback.length > maxScrollback) {
          _scrollback.removeAt(0);
          if (_unread > _scrollback.length) _unread = _scrollback.length;
        }
      }
      _grid.insert(_bottom, _blank());
    }
  }

  void _scrollDown(int n) {
    for (var k = 0; k < n; k++) {
      _grid.removeAt(_bottom);
      _grid.insert(_top, _blank());
    }
  }

  void _insertLines(int n) {
    for (var k = 0; k < n; k++) {
      _grid.removeAt(_bottom);
      _grid.insert(_row, _blank());
    }
  }

  void _deleteLines(int n) {
    for (var k = 0; k < n; k++) {
      _grid.removeAt(_row);
      _grid.insert(_bottom, _blank());
    }
  }

  void _eraseLine(int row, {int from = 0, int? to}) {
    final end = (to ?? cols - 1).clamp(0, cols - 1);
    for (var c = from.clamp(0, cols); c <= end; c++) {
      _grid[row][c] = 32;
    }
  }

  void _reset() {
    for (var r = 0; r < rows; r++) {
      _eraseLine(r);
    }
    _row = _col = 0;
    _top = 0;
    _bottom = rows - 1;
    _wrapPending = false;
  }
}

class _TextSink implements Sink<String> {
  _TextSink(this._on);
  final void Function(String) _on;

  @override
  void add(String data) => _on(data);

  @override
  void close() {}
}
