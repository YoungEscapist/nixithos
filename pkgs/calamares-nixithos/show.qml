/* The slides shown while NixithOS installs: one tip each, about what the
 * installed system really has (nixith, s6-rc, the generations...), some
 * with a screenshot of it (images/, made from branding/screenshots).
 * A click or the arrow keys go on; the bars at the bottom say where.
 * (slideshowAPI 2: Calamares sets activatedInCalamares and calls
 * onActivate/onLeave.) */
import QtQuick

Item {
    id: root

    property bool activatedInCalamares: false
    property int current: 0
    property real progress: 0
    readonly property int interval: 11000

    readonly property var tips: [
        { kicker: "NixithOS",
          title: "NixOS, without systemd",
          body: "PID 1 is s6-linux-init, services run under s6-rc, devices are eudev's and logs s6-log's. The packages, the modules and configuration.nix are NixOS's own.",
          cmd: "cat /proc/1/comm      # s6-svscan" },
        { kicker: "Configuration",
          title: "One file describes the whole system",
          body: "Users, services, desktop, packages: everything is in /etc/nixith/configuration.nix. Change it, then build and switch to it in one go.",
          cmd: "sudo nixith switch" },
        { kicker: "Configuration",
          title: "Rebuild only the part you changed",
          body: "--only takes an option or a group of them; everything else stays exactly as in the running system, even half-done edits elsewhere in the file.",
          cmd: "sudo nixith switch --only services.openssh" },
        { kicker: "Generations",
          title: "Every change can be undone",
          body: "Each switch is a new generation, and the boot menu lists them all. Something broke? Go back to the previous one, or pick it when the machine starts.",
          cmd: "nixith generations\nsudo nixith rollback",
          img: "images/dwl.jpg" },
        { kicker: "Generations",
          title: "Try a configuration before keeping it",
          body: "build-vm builds the same system into a script that starts it in QEMU, without touching the one you are running.",
          cmd: "nixith build-vm && ./result/bin/run-*-vm" },
        { kicker: "Services",
          title: "systemctl still works",
          body: "It is a thin wrapper over s6-rc: start, stop, restart, status. The native tools are there too.",
          cmd: "systemctl restart sshd\ns6-rc -a list" },
        { kicker: "Services",
          title: "Logs are plain files",
          body: "Every service writes to /var/log/s6/<service>/ through its own logger; journalctl -u reads those directories.",
          cmd: "journalctl -u sshd -f\ntail -F /var/log/s6/sshd/current" },
        { kicker: "Packages",
          title: "Over 140 000 packages, from the cache",
          body: "NixithOS uses the same nixpkgs and the same binaries as NixOS; only libsystemd and libudev are swapped for elogind's and eudev's under them. Nothing is compiled.",
          img: "images/parallax.jpg" },
        { kicker: "Packages",
          title: "Use a program without installing it",
          body: "nix-shell gives you a shell with the packages you name; when you leave it, nothing has changed in the system.",
          cmd: "nix-shell -p htop ripgrep" },
        { kicker: "Packages",
          title: "Install for good",
          body: "Add the package to environment.systemPackages (for everyone) or to users.users.<you>.packages, and switch. search.nixos.org has the names.",
          cmd: "environment.systemPackages = [ pkgs.btop ];" },
        { kicker: "Desktops",
          title: "Add another desktop at any time",
          body: "Parallax, GNOME, Plasma, Hyprland, niri and dwl are one line each; every one you enable shows up in the login screen's list of sessions.",
          cmd: "nixithos.desktop.niri.enable = true;",
          img: "images/dm-ly.jpg" },
        { kicker: "Desktops",
          title: "The first keys to know",
          body: "Hyprland: Super+Q a terminal, Super+R programs, Super+M log out.\nniri: Super+T, Super+D, Super+Shift+/ for all the keys.\ndwl: Super+Shift+Enter, Super+P, Super+Shift+Q.",
          img: "images/hyprland.jpg" },
        { kicker: "Shells",
          title: "Another shell later",
          body: "bash, zsh, fish or nushell: the shell is a line in the configuration too, per user.",
          cmd: "programs.fish.enable = true;\nusers.users.<you>.shell = pkgs.fish;",
          img: "images/shell-fish.jpg" },
        { kicker: "Network",
          title: "Wi-Fi from the terminal",
          body: "NetworkManager is on; nmtui finds the networks and asks for the password. Desktops show it in their panels as well.",
          cmd: "nmtui" },
        { kicker: "Flakes",
          title: "Flakes work, with your own nixpkgs",
          body: "nixith builds nixithConfigurations.<host> (or nixosConfigurations.<host>) of a flake as readily as configuration.nix.",
          cmd: "sudo nixith switch --flake /etc/nixith#box" },
        { kicker: "Housekeeping",
          title: "Free the disk of old generations",
          body: "Old generations keep their packages in the store until you collect them; the next build tidies the boot menu.",
          cmd: "sudo nix-collect-garbage -d\nsudo nixith boot" },
        { kicker: "Almost there",
          title: "When it is done",
          body: "Remove the installation medium and restart. The boot menu will show NixithOS; your configuration is waiting in /etc/nixith.",
          cmd: "nixith parts      # what the system was built from" }
    ]

    function go(i) {
        current = (i + tips.length) % tips.length
        advance.restart()
    }
    function onActivate() { go(0) }
    function onLeave() { advance.stop() }

    focus: activatedInCalamares
    Keys.onRightPressed: go(current + 1)
    Keys.onLeftPressed: go(current - 1)

    Rectangle { anchors.fill: parent; color: "#000000" }

    // the slide: faded in again whenever `current` changes (from 0.15: one
    // faded in from 0 stayed blank with Qt Quick's software renderer)
    Item {
        id: slide
        anchors.fill: parent
        anchors.margins: 22
        anchors.bottomMargin: 34
        property var tip: root.tips[root.current]
        property bool hasImg: tip.img !== undefined

        onTipChanged: fade.restart()
        NumberAnimation {
            id: fade
            target: slide; property: "opacity"
            from: 0.15; to: 1; duration: 350
            easing.type: Easing.OutCubic
        }

        Row {
            id: head
            spacing: 8
            Image {
                source: "nixithos.png"
                width: 18; height: 18
                fillMode: Image.PreserveAspectFit
                smooth: true
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: slide.tip.kicker.toUpperCase()
                color: "#8A8A8A"
                font.pixelSize: 11
                font.letterSpacing: 2
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        Text {
            anchors.right: parent.right
            anchors.verticalCenter: head.verticalCenter
            text: (root.current + 1) + " / " + root.tips.length
            color: "#5A5A5A"
            font.pixelSize: 11
            font.family: "monospace"
        }

        // what is on the slide: the screenshot (or the mark) above the text,
        // all of it in the middle; it grows with the window, up to a point
        Column {
            id: content
            readonly property real s: Math.max(1, Math.min(1.6, slide.width / 640))
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: head.height / 2
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, 560 * s)
            spacing: 8 * s

            Rectangle {
                id: shot
                visible: slide.hasImg
                anchors.horizontalCenter: parent.horizontalCenter
                height: visible ? Math.min(slide.height * 0.5, content.width / 1.6) : 0
                width: height * 1.6
                color: "#0B0B0B"
                border.color: "#2A2A2A"
                border.width: 1
                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    source: slide.hasImg ? slide.tip.img : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                }
            }
            Image {
                visible: !slide.hasImg
                anchors.horizontalCenter: parent.horizontalCenter
                source: "nixithos.png"
                height: visible ? Math.min(slide.height * 0.3, 120 * content.s) : 0
                width: height
                fillMode: Image.PreserveAspectFit
                smooth: true
                opacity: 0.9
            }
            Item { width: 1; height: 6 * content.s }

            Text {
                width: parent.width
                text: slide.tip.title
                color: "#FFFFFF"
                font.pixelSize: Math.round(21 * content.s)
                font.bold: true
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                text: slide.tip.body
                color: "#B4B4B4"
                font.pixelSize: Math.round(13 * content.s)
                lineHeight: 1.2
                wrapMode: Text.WordWrap
            }
            Item { width: 1; height: 2 * content.s; visible: cmdBox.visible }
            Rectangle {
                id: cmdBox
                visible: slide.tip.cmd !== undefined
                width: Math.min(parent.width, cmdText.implicitWidth + 28 * content.s)
                height: cmdText.implicitHeight + 16 * content.s
                color: "#111111"
                border.color: "#2A2A2A"
                border.width: 1
                radius: 4
                Rectangle {
                    width: 3
                    color: "#E6E6E6"
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: 1
                }
                Text {
                    id: cmdText
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 16 * content.s
                    width: Math.min(implicitWidth, content.width - 28 * content.s)
                    text: cmdBox.visible ? slide.tip.cmd : ""
                    color: "#E6E6E6"
                    font.family: "monospace"
                    font.pixelSize: Math.round(13 * content.s)
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }

    // where we are: a bar per tip, the current one filling up
    Row {
        id: bars
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 22
        anchors.bottomMargin: 16
        spacing: 4
        Repeater {
            model: root.tips.length
            Rectangle {
                width: (bars.width - bars.spacing * (root.tips.length - 1)) / root.tips.length
                height: 3
                radius: 1.5
                color: index < root.current ? "#8A8A8A" : "#262626"
                Rectangle {
                    visible: index === root.current
                    height: parent.height
                    radius: parent.radius
                    color: "#FFFFFF"
                    width: parent.width * root.progress
                }
            }
        }
    }
    NumberAnimation {
        id: advance
        target: root; property: "progress"
        from: 0; to: 1
        duration: root.interval
        running: root.activatedInCalamares
        onFinished: if (root.activatedInCalamares) root.go(root.current + 1)
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.go(root.current + 1)
    }
}
