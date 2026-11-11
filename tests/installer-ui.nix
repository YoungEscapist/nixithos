# Drive the real encryption form and the release step in a PTY, without
# networking or disk access.
{ pkgs }:
let
  harness = pkgs.writeText "installer-encryption-ui.c" ''
    #define main installer_main
    #include "${../pkgs/nixith-installer/installer.c}"
    #undef main
    int main(void) {
      setlocale(LC_ALL, "");
      utf8 = 1; S.efi = 1; dry = 1; pic_mode = PIC_NONE;
      initscr(); cbreak(); noecho(); keypad(stdscr, TRUE);
      start_color(); use_default_colors();
      init_pair(C_NORMAL, COLOR_WHITE, -1);
      init_pair(C_DIM, COLOR_BLACK, -1);
      init_pair(C_SEL, COLOR_BLACK, COLOR_WHITE);
      init_pair(C_ERR, COLOR_RED, -1);
      init_pair(C_HEAD, COLOR_BLACK, COLOR_WHITE);
      int result = disk_encryption();
      /* the release: the second one, and the kernels are then named by its versions */
      S.online = 1;
      int release = step_release();
      endwin();
      return !(result == NEXT && S.encrypt &&
        !strcmp(S.luks_pw, "test-only-pass") && !strcmp(S.luks_repeat, S.luks_pw) &&
        release == NEXT && !strcmp(releases[S.release].id, "unstable") &&
        !strcmp(kernel_name(1), "Linux unstable-latest"));
    }
  '';
in pkgs.runCommand "installer-encryption-ui" {
  nativeBuildInputs = [ pkgs.stdenv.cc pkgs.pkg-config pkgs.python3 ];
  buildInputs = [ pkgs.ncurses pkgs.libxcrypt ];
} ''
  $CC -O1 -I${pkgs.stb}/include/stb \
    -DK_LTS='"test"' -DK_LATEST='"test"' -DK_6_12='"test"' -DK_6_6='"test"' \
    -DK_ZEN='"test"' -DK_XANMOD='"test"' \
    -DKU_LTS='"u"' -DKU_LATEST='"unstable-latest"' -DKU_6_12='"u"' -DKU_6_6='"u"' \
    -DKU_ZEN='"u"' -DKU_XANMOD='"u"' \
    ${harness} -o ui $(pkg-config --cflags --libs ncursesw) -lcrypt -lm
  python3 - <<'PY'
  import os, pty, fcntl, termios, struct, subprocess, select, time
  master, slave = pty.openpty()
  fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
  proc = subprocess.Popen(['./ui'], stdin=slave, stdout=slave, stderr=slave,
      env={**os.environ, 'TERM':'xterm-256color', 'LANG':'C.UTF-8'})
  os.close(slave)
  output = b""
  def wait_for(text):
      global output
      end = time.monotonic() + 10
      while time.monotonic() < end:
          if select.select([master], [], [], .1)[0]:
              output += os.read(master, 65536)
              if text.encode() in output: return
      raise AssertionError('UI did not show ' + text)
  try:
      wait_for('Disk encryption')
      os.write(master, b'\x1bOB\n')
      wait_for('Unlocking the disk')
      os.write(master, b'\n')
      wait_for('Enter a passphrase.')
      os.write(master, b'test-only-pass\twrong\n')
      wait_for('The passphrases differ.')
      os.write(master, b'\x7f'*5 + b'test-only-pass\n')
      wait_for('Zokor (unstable)')
      os.write(master, b'\x1bOB\n')
      assert proc.wait(timeout=10) == 0
      assert b'test-only-pass' not in output and b'wrong' not in output, 'Passphrase exposed'
      print('PASS: encryption selection, empty/mismatched key rejection, masked confirmation, release step')
  finally:
      if proc.poll() is None:
          proc.kill(); proc.wait()
      os.close(master)
  PY
  touch $out
''
