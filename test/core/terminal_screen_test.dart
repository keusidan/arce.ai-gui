import 'dart:convert';

import 'package:arce_ai/core/terminal_screen.dart';
import 'package:flutter_test/flutter_test.dart';

TerminalScreen screen({int cols = 20, int rows = 5}) => TerminalScreen(cols: cols, rows: rows);

void write(TerminalScreen s, String text) => s.feed(utf8.encode(text));

void main() {
  group('printing', () {
    test('lines, the carriage return and the backspace', () {
      final s = screen();
      write(s, 'hello\r\nworld');
      expect(s.text(), 'hello\nworld');
      write(s, '\rWO');
      expect(s.text(), 'hello\nWOrld');
      write(s, '\b\bxy');
      expect(s.text(), 'hello\nxyrld');
    });

    test('a progress line redrawn with \\r shows its last state, not every state', () {
      final s = screen();
      write(s, 'downloading  10%\rdownloading  50%\rdownloading 100%');
      expect(s.text(), 'downloading 100%');
    });

    test('a long line wraps at the width, and a tab goes to the next stop of 8', () {
      final s = screen(cols: 10);
      write(s, '0123456789ABC');
      expect(s.text(), '0123456789\nABC');
      final t = screen();
      write(t, 'a\tb');
      expect(t.text(), 'a       b');
    });

    test('Japanese text and a character that arrives in two pieces', () {
      final s = screen();
      final bytes = utf8.encode('日本語');
      s.feed(bytes.sublist(0, 4)); // cuts the second character
      s.feed(bytes.sublist(4));
      expect(s.text(), '日本語');
    });
  });

  group('escape sequences', () {
    test('colours and styles are dropped, so the text reads as plain text', () {
      final s = screen(cols: 40);
      write(s, '\x1b[1;31merror:\x1b[0m something \x1b[38;5;208mwent\x1b[0m wrong');
      expect(s.text(), 'error: something went wrong');
      expect(s.scrollback, isEmpty);
    });

    test('the cursor moves: a menu that redraws itself in place', () {
      final s = screen();
      write(s, '> one\r\n  two\r\n  three');
      write(s, '\x1b[3A\r  one\r\n> two');
      expect(s.text(), '  one\n> two\n  three');
      write(s, '\x1b[H\x1b[2J');
      expect(s.text(), isEmpty);
      write(s, '\x1b[3;5Hx');
      expect(s.text(), '\n\n    x');
    });

    test('erasing: to the end of the line, to the start, the whole line, and below', () {
      final s = screen();
      write(s, 'abcdefghij\r\nsecond\r\nthird');
      write(s, '\x1b[1;4H\x1b[K');
      expect(s.text().split('\n').first, 'abc');
      write(s, '\x1b[2;3H\x1b[1K');
      expect(s.text().split('\n')[1], '   ond');
      write(s, '\x1b[3;1H\x1b[2K');
      expect(s.text().split('\n'), hasLength(2));
      write(s, '\x1b[1;1H\x1b[J');
      expect(s.text(), isEmpty);
    });

    test('inserting and deleting lines and characters', () {
      final s = screen();
      write(s, 'one\r\ntwo\r\nthree');
      write(s, '\x1b[2;1H\x1b[L');
      expect(s.text(), 'one\n\ntwo\nthree');
      write(s, '\x1b[2;1H\x1b[M');
      expect(s.text(), 'one\ntwo\nthree');
      write(s, '\x1b[1;2H\x1b[P');
      expect(s.text().split('\n').first, 'oe');
      write(s, '\x1b[1;2H\x1b[2@');
      expect(s.text().split('\n').first, 'o  e');
    });

    test('the title, charset and mode sequences are read and ignored', () {
      final s = screen();
      write(s, '\x1b]0;window title\x07\x1b(B\x1b[?25l\x1b[?1049hshown\x1b[?25h');
      expect(s.text(), 'shown');
    });

    test('a sequence cut between two pieces is finished when the rest arrives', () {
      final s = screen();
      write(s, 'ab\x1b[');
      write(s, '31mcd');
      expect(s.text(), 'abcd');
      write(s, '\x1b]0;ti');
      write(s, 'tle\x07ef');
      expect(s.text(), 'abcdef');
    });

    test('save and restore the cursor; reverse index at the top scrolls the screen down', () {
      final s = screen();
      write(s, 'abc\x1b7\r\nxyz\x1b8Z');
      expect(s.text(), 'abcZ\nxyz');
      final t = screen(rows: 3);
      write(t, 'one\r\ntwo');
      write(t, '\x1b[H\x1bM');
      expect(t.text(), '\none\ntwo');
    });

    test('a scroll region keeps a header and a footer where they are', () {
      final s = screen(rows: 4);
      write(s, 'HEAD\x1b[2;3r\x1b[2;1Ha\r\nb\r\nc\r\nd');
      // lines 2 and 3 scroll; line 1 stays; nothing is lost to the scrollback (the region is not the top)
      expect(s.text().split('\n').first, 'HEAD');
      expect(s.text(), contains('d'));
      expect(s.scrollback, isEmpty);
    });
  });

  group('scrolling', () {
    test('what scrolled off the top is kept, and handed out once', () {
      final s = screen(rows: 3);
      write(s, 'a\r\nb\r\nc\r\nd\r\ne');
      expect(s.text(), 'c\nd\ne');
      expect(s.scrollback, ['a', 'b']);
      expect(s.takeScrolled(), ['a', 'b']);
      expect(s.takeScrolled(), isEmpty);
      write(s, '\r\nf');
      expect(s.takeScrolled(), ['c']);
      expect(s.scrollback, ['a', 'b', 'c']);
    });

    test('only the most recent lines are kept, and the unread ones never outnumber them', () {
      final s = TerminalScreen(cols: 10, rows: 2, maxScrollback: 3);
      for (var i = 0; i < 10; i++) {
        write(s, 'line$i\r\n');
      }
      expect(s.scrollback, ['line6', 'line7', 'line8']);
      expect(s.takeScrolled(), ['line6', 'line7', 'line8']);
    });

    test('a full reset clears the screen', () {
      final s = screen();
      write(s, 'junk\r\nmore\x1bcfresh');
      expect(s.text(), 'fresh');
    });
  });

  test('a program that writes a lot of garbage does not break it', () {
    final s = screen();
    write(s, List.generate(2000, (i) => String.fromCharCode(1 + i % 31)).join());
    write(s, '\x1b[999;999H\x1b[999A\x1b[999B\x1b[999C\x1b[999D\x1b[0;0H\x1b[;H');
    write(s, '\x1b[999L\x1b[999M\x1b[999P\x1b[999@\x1b[999X\x1b[99S\x1b[99T');
    write(s, 'ok');
    expect(s.text(), contains('ok'));
  });
}
