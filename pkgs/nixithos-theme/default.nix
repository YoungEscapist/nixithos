# The look of NixithOS, out of its mark (../../branding/nixithos.png): white
# lines on black, and nothing else.  Pictures for every place that shows
# something before or around a desktop:
#
#   share/backgrounds/nixithos/   wallpapers (16:9 at 3840x2160, 21:9 at 2560x1080)
#   share/nixithos/limine/        the background of Limine's menu
#   share/nixithos/grub/          a GRUB theme (theme.txt, its pictures and fonts)
#   share/nixithos/refind/        rEFInd's banner, selection and icons
#   share/nixithos/ly/nixithos.dur  the mark in characters, for ly's dur_file
#
# Colours: background #0a0a0b, lines #a4a4aa, text #c8c8cc, dim #5a5a5e.
{
  runCommand,
  imagemagick,
  python3,
  grub2,
  dejavu_fonts,
}:

runCommand "nixithos-theme"
  {
    nativeBuildInputs = [
      imagemagick
      python3
      grub2
    ];
    sans = "${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
    mono = "${dejavu_fonts}/share/fonts/truetype/DejaVuSansMono.ttf";
  }
  ''
    # the mark alone, square, out of the 1536x1024 picture, as a grey mask
    # (its black is not quite black: compression noise, levelled away)
    magick ${../../branding/nixithos.png} -crop 680x680+428+154 +repage \
      -colorspace Gray -level 35%,75% -type Grayscale mark.png

    # mark <size> <colour> <glow 0..1>: the mark in a colour, on transparency,
    # with a soft glow of its own lines under it
    mark() {
      magick \( mark.png -filter Lanczos -resize "$1x$1" -blur 0x$(( $1 / 55 )) \
                 -evaluate multiply "$3" -alpha copy -fill "$2" -colorize 100 \) \
             \( mark.png -filter Lanczos -resize "$1x$1" -alpha copy -fill "$2" -colorize 100 \) \
             -compose over -composite "$4"
    }
    # vignette <w> <h>: a darkening towards the corners, to multiply with
    vignette() {
      d=$(( ($1 > $2 ? $1 : $2) * 3 / 2 ))
      magick -size "''${d}x''${d}" radial-gradient:'#ffffff'-'#8a8a8a' \
        -gravity center -crop "$1x$2+0+0" +repage "$3"
    }

    # ── wallpapers ──────────────────────────────────────────────────────
    out_bg=$out/share/backgrounds/nixithos
    mkdir -p $out_bg
    wall() { # <w> <h> <mark size> <out>
      mark "$3" '#a4a4aa' 0.55 m.png
      vignette "$1" "$2" v.png
      magick -size "$1x$2" xc:'#0a0a0b' m.png -gravity center -composite \
        v.png -compose multiply -composite -type TrueColor "$4"
    }
    wall 3840 2160 1000 $out_bg/nixithos.png
    wall 2560 1080 560 $out_bg/nixithos-21x9.png
    # the mark small, the screen nearly empty
    wall 3840 2160 520 $out_bg/nixithos-small.png

    # ── Limine ──────────────────────────────────────────────────────────
    # (centred, not stretched: the menu is drawn over the middle of the
    # screen, so the mark is dim; the rest of a wider screen is the backdrop)
    mkdir -p $out/share/nixithos/limine
    mark 720 '#a4a4aa' 0.4 m.png
    magick -size 1920x1080 xc:'#0a0a0b' \( m.png -evaluate multiply 0.30 \) -gravity center -composite \
      -type TrueColor $out/share/nixithos/limine/background.png

    # ── GRUB ────────────────────────────────────────────────────────────
    g=$out/share/nixithos/grub
    mkdir -p $g
    mark 400 '#a4a4aa' 0.5 m.png
    magick -size 1920x1080 xc:'#0a0a0b' m.png -gravity north -geometry +0+110 -composite \
      -font "$sans" -pointsize 30 -kerning 14 -fill '#c8c8cc' -gravity north -annotate +0+560 'NIXITHOS' \
      -type TrueColor $g/background.png
    # the selected entry: a dark grey bar with a line on its left
    for p in nw n ne w e sw s se; do magick -size 4x4 xc:'#161618' $g/select_$p.png; done
    magick -size 4x4 xc:'#161618' $g/select_c.png
    magick -size 4x4 xc:'#161618' -fill '#c8c8cc' -draw 'rectangle 0,0 1,3' $g/select_w.png
    grub-mkfont -s 20 -n "NixithOS Sans" -o $g/sans-20.pf2 "$sans"
    grub-mkfont -s 16 -n "NixithOS Sans" -o $g/sans-16.pf2 "$sans"
    grub-mkfont -s 16 -n "NixithOS Mono" -o $g/mono-16.pf2 "$mono"
    cat > $g/theme.txt <<'EOF'
    # NixithOS: the mark above, the menu below it, nothing else
    desktop-image: "background.png"
    desktop-image-scale-method: "crop"
    desktop-color: "#0a0a0b"
    title-text: ""
    terminal-font: "NixithOS Mono Regular 16"
    terminal-box: "select_*.png"

    + boot_menu {
      left = 30%
      width = 40%
      top = 62%
      height = 26%
      item_font = "NixithOS Sans Regular 20"
      item_color = "#6e6e72"
      selected_item_font = "NixithOS Sans Regular 20"
      selected_item_color = "#f0f0f2"
      item_height = 36
      item_padding = 14
      item_spacing = 4
      icon_width = 0
      icon_height = 0
      item_icon_space = 0
      selected_item_pixmap_style = "select_*.png"
      scrollbar = false
    }

    + label {
      id = "__timeout__"
      left = 0
      top = 93%
      width = 100%
      align = "center"
      font = "NixithOS Sans Regular 16"
      color = "#5a5a5e"
      text = "%d"
    }
    EOF

    # ── rEFInd ──────────────────────────────────────────────────────────
    r=$out/share/nixithos/refind
    mkdir -p $r/icons
    mark 360 '#a4a4aa' 0.5 m.png
    magick -size 1920x1080 xc:'#0a0a0b' m.png -gravity north -geometry +0+170 -composite \
      -type TrueColor $r/background.png
    # an entry's icon: the mark; selected, a faint square behind it
    mark 128 '#c8c8cc' 0.0 $r/icons/os_linux.png
    cp $r/icons/os_linux.png $r/icons/os_nixos.png
    cp $r/icons/os_linux.png $r/icons/os_unknown.png
    magick -size 144x144 xc:none -fill '#1a1a1c' -draw 'roundrectangle 0,0 143,143 18,18' $r/selection_big.png
    magick -size 64x64 xc:none -fill '#1a1a1c' -draw 'roundrectangle 0,0 63,63 10,10' $r/selection_small.png

    # ── ly ──────────────────────────────────────────────────────────────
    mkdir -p $out/share/nixithos/ly
    python3 ${../../branding/mkdur.py} 61 $out/share/nixithos/ly/nixithos.dur
  ''
