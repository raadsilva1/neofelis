#!/bin/ksh
# neofelis-bootstrap.ksh
# Non-interactive installer for neofelis on Artix Linux x86_64 with OpenRC only.

set -eu
(set -o pipefail) >/dev/null 2>&1 && set -o pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
umask 022

PROJECT="neofelis"
VERSION="1.0.0"
INSTALL_BIN="/usr/local/bin/neofelis"
INSTALL_DESKTOP="/usr/local/share/applications/neofelis.desktop"
REQUIRED_PACKAGES="perl perl-gtk3"

TMPROOT=""
STAGE_DIR=""
BACKUP_DIR=""
INSTALL_OK=0
HAD_OLD_BIN=0
HAD_OLD_DESKTOP=0

log() {
    printf '%s\n' "[neofelis] $*"
}

warn() {
    printf '%s\n' "[neofelis] warning: $*" >&2
}

die() {
    printf '%s\n' "[neofelis] error: $*" >&2
    exit 1
}

cleanup() {
    rc=$?
    set +e

    if [ "$INSTALL_OK" -ne 1 ]; then
        if [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
            if [ "$HAD_OLD_BIN" -eq 1 ] && [ -f "$BACKUP_DIR/neofelis.bin" ]; then
                cp -f "$BACKUP_DIR/neofelis.bin" "$INSTALL_BIN"
                chmod 0755 "$INSTALL_BIN" 2>/dev/null || true
            else
                rm -f "$INSTALL_BIN" "$INSTALL_BIN.neofelis.new."* 2>/dev/null || true
            fi

            if [ "$HAD_OLD_DESKTOP" -eq 1 ] && [ -f "$BACKUP_DIR/neofelis.desktop" ]; then
                cp -f "$BACKUP_DIR/neofelis.desktop" "$INSTALL_DESKTOP"
                chmod 0644 "$INSTALL_DESKTOP" 2>/dev/null || true
            else
                rm -f "$INSTALL_DESKTOP" "$INSTALL_DESKTOP.neofelis.new."* 2>/dev/null || true
            fi
        fi
    fi

    if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then
        rm -rf "$TMPROOT"
    fi

    exit $rc
}

trap cleanup EXIT INT TERM HUP

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

assert_target_system() {
    [ "$(uname -s)" = "Linux" ] || die "target OS must be Linux"
    [ "$(uname -m)" = "x86_64" ] || die "target architecture must be x86_64"

    [ -r /etc/os-release ] || die "/etc/os-release not found"
    os_id=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
    [ "$os_id" = "artix" ] || die "this installer targets Artix Linux only"

    if [ ! -d /run/openrc ] && [ ! -x /sbin/openrc-run ] && [ ! -x /usr/bin/openrc-run ]; then
        die "OpenRC environment not detected"
    fi
}

assert_root() {
    uid=$(id -u)
    [ "$uid" -eq 0 ] || die "run this installer as root"
}

make_workspace() {
    TMPROOT=$(mktemp -d /tmp/neofelis.XXXXXX) || die "mktemp failed"
    STAGE_DIR="$TMPROOT/stage"
    BACKUP_DIR="$TMPROOT/backup"
    mkdir -p "$STAGE_DIR" "$BACKUP_DIR"
}

check_package_visible() {
    pkg="$1"
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

install_dependencies() {
    log "checking package visibility"
    for pkg in $REQUIRED_PACKAGES; do
        if ! check_package_visible "$pkg"; then
            die "package '$pkg' is not visible to pacman. On Artix, keep Artix repos above Arch repos, and if needed enable Arch repo support with artix-archlinux-support before re-running."
        fi
    done

    log "installing runtime dependencies"
    pacman -S --needed --noconfirm $REQUIRED_PACKAGES >/dev/null
}

write_payloads() {
    log "writing staged project files"

    cat > "$STAGE_DIR/neofelis" <<'__NEOFELIS_PERL__'
#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use feature qw(say);
use Getopt::Long qw(GetOptions);
use Fcntl qw(:DEFAULT F_GETFD F_SETFD FD_CLOEXEC O_RDONLY O_WRONLY O_CREAT O_EXCL);
use File::Spec;
use File::Path qw(make_path);
use POSIX qw(setsid _exit);
use IO::Handle ();
use Encode qw(encode decode FB_CROAK);
use Gtk3 '-init';

use constant TRUE  => 1;
use constant FALSE => 0;

my %OPT = (
    debug         => 0,
    no_history    => 0,
    clear_history => 0,
    help          => 0,
);

GetOptions(
    'debug'         => \$OPT{debug},
    'no-history'    => \$OPT{no_history},
    'clear-history' => \$OPT{clear_history},
    'help'          => \$OPT{help},
) or die usage();

if ($OPT{help}) {
    print usage();
    exit 0;
}

my %PATHS = build_paths();
my $MAX_HISTORY = 200;
my $MAX_SUGGESTIONS = 6;
my %APP = (
    history               => [],
    history_parse_failed  => 0,
    history_warning       => undef,
    validation_text       => undef,
    validation_result     => undef,
    suggestions           => [],
);

if ($OPT{clear_history}) {
    my ($ok, $err) = clear_history_file($PATHS{history_file});
    if ($ok) {
        say "neofelis: history cleared";
        exit 0;
    }
    die "neofelis: failed to clear history: $err\n";
}

unless ($OPT{no_history}) {
    my ($history, $warning, $parse_failed) = load_history($PATHS{history_file}, $MAX_HISTORY);
    $APP{history}              = $history;
    $APP{history_warning}      = $warning;
    $APP{history_parse_failed} = $parse_failed;
}

my $window = Gtk3::Window->new('toplevel');
$window->set_title('neofelis');
$window->set_default_size(680, 280);
$window->set_resizable(FALSE);
$window->set_border_width(0);
$window->set_position('center');
$window->signal_connect(delete_event => sub { Gtk3::main_quit(); return FALSE; });

install_css();

my $root = Gtk3::Box->new('vertical', 0);
$root->get_style_context->add_class('root');
$window->add($root);

my $frame = Gtk3::Box->new('vertical', 10);
$frame->set_border_width(16);
$root->pack_start($frame, TRUE, TRUE, 0);

my $title = Gtk3::Label->new('Run a command');
$title->set_xalign(0.0);
$title->get_style_context->add_class('title');
$frame->pack_start($title, FALSE, FALSE, 0);

my $subtitle = Gtk3::Label->new('Validated before launch. Recent successful commands are suggested below.');
$subtitle->set_xalign(0.0);
$subtitle->set_line_wrap(TRUE);
$subtitle->get_style_context->add_class('subtitle');
$frame->pack_start($subtitle, FALSE, FALSE, 0);

my $entry = Gtk3::Entry->new();
$entry->set_hexpand(TRUE);
$entry->set_activates_default(FALSE);
$entry->set_placeholder_text('e.g. alacritty -e htop');
$entry->get_style_context->add_class('command-entry');
$frame->pack_start($entry, FALSE, FALSE, 0);

my $suggestion_wrap = Gtk3::Frame->new(undef);
$suggestion_wrap->set_shadow_type('in');
$suggestion_wrap->get_style_context->add_class('suggestions-wrap');
$frame->pack_start($suggestion_wrap, TRUE, TRUE, 0);

my $suggestion_scroll = Gtk3::ScrolledWindow->new();
$suggestion_scroll->set_policy('never', 'automatic');
$suggestion_scroll->set_min_content_height(118);
$suggestion_scroll->set_propagate_natural_height(TRUE);
$suggestion_wrap->add($suggestion_scroll);

my $suggestion_list = Gtk3::ListBox->new();
$suggestion_list->set_selection_mode('browse');
$suggestion_list->set_activate_on_single_click(TRUE);
$suggestion_scroll->add($suggestion_list);

my $status = Gtk3::Label->new('');
$status->set_xalign(0.0);
$status->set_line_wrap(TRUE);
$status->get_style_context->add_class('status');
$frame->pack_start($status, FALSE, FALSE, 0);

my $buttons = Gtk3::Box->new('horizontal', 8);
$frame->pack_start($buttons, FALSE, FALSE, 0);

my $clear_btn = Gtk3::Button->new_with_label('Clear history');
$clear_btn->set_sensitive(!$OPT{no_history});
$clear_btn->get_style_context->add_class('secondary-button');
$buttons->pack_start($clear_btn, FALSE, FALSE, 0);

my $spacer = Gtk3::Box->new('horizontal', 0);
$buttons->pack_start($spacer, TRUE, TRUE, 0);

my $cancel_btn = Gtk3::Button->new_with_label('Cancel');
$cancel_btn->get_style_context->add_class('secondary-button');
$buttons->pack_start($cancel_btn, FALSE, FALSE, 0);

my $run_btn = Gtk3::Button->new_with_label('Run');
$run_btn->get_style_context->add_class('suggested-action');
$run_btn->set_sensitive(FALSE);
$buttons->pack_start($run_btn, FALSE, FALSE, 0);

$cancel_btn->signal_connect(clicked => sub { Gtk3::main_quit(); });
$window->signal_connect(key_press_event => sub {
    my ($widget, $event) = @_;
    my $key = Gtk3::Gdk::keyval_name($event->keyval) // '';
    if ($key eq 'Escape') {
        Gtk3::main_quit();
        return TRUE;
    }
    return FALSE;
});

$entry->signal_connect(changed => sub {
    refresh_ui(
        entry           => $entry,
        run_btn         => $run_btn,
        status          => $status,
        suggestion_list => $suggestion_list,
    );
});

$entry->signal_connect(key_press_event => sub {
    my ($widget, $event) = @_;
    my $key = Gtk3::Gdk::keyval_name($event->keyval) // '';
    if ($key eq 'Return' || $key eq 'KP_Enter') {
        if ($run_btn->get_sensitive) {
            run_current_command(
                entry   => $entry,
                run_btn => $run_btn,
                status  => $status,
                window  => $window,
            );
            return TRUE;
        }
    }
    elsif ($key eq 'Tab' || $key eq 'ISO_Left_Tab') {
        if (my $completion = current_completion($entry->get_text, $APP{suggestions})) {
            $entry->set_text($completion);
            $entry->set_position(length($completion));
            refresh_ui(
                entry           => $entry,
                run_btn         => $run_btn,
                status          => $status,
                suggestion_list => $suggestion_list,
            );
            return TRUE;
        }
    }
    elsif ($key eq 'Down') {
        my $row = $suggestion_list->get_row_at_index(0);
        if ($row) {
            $suggestion_list->select_row($row);
            $suggestion_list->grab_focus;
            return TRUE;
        }
    }
    return FALSE;
});

$suggestion_list->signal_connect(row_activated => sub {
    my ($list, $row) = @_;
    apply_suggestion_row($entry, $row);
});

$suggestion_list->signal_connect(key_press_event => sub {
    my ($list, $event) = @_;
    my $key = Gtk3::Gdk::keyval_name($event->keyval) // '';
    my $row = $list->get_selected_row;
    if (($key eq 'Return' || $key eq 'KP_Enter' || $key eq 'Tab') && $row) {
        apply_suggestion_row($entry, $row);
        return TRUE;
    }
    if ($key eq 'Up' && $row && $row->get_index == 0) {
        $entry->grab_focus;
        $entry->set_position(length($entry->get_text));
        return TRUE;
    }
    return FALSE;
});

$clear_btn->signal_connect(clicked => sub {
    my $dialog = Gtk3::MessageDialog->new(
        $window,
        ['modal', 'destroy-with-parent'],
        'question',
        'yes-no',
        'Clear neofelis history?'
    );
    $dialog->format_secondary_text(
        $OPT{no_history}
            ? 'History storage is disabled for this session.'
            : 'This removes stored successful commands from disk.'
    );
    my $response = $dialog->run;
    $dialog->destroy;
    return unless $response eq 'yes';

    my ($ok, $err) = clear_history_file($PATHS{history_file});
    if ($ok) {
        $APP{history}              = [];
        $APP{history_warning}      = 'History cleared.';
        $APP{history_parse_failed} = 0;
        refresh_ui(
            entry           => $entry,
            run_btn         => $run_btn,
            status          => $status,
            suggestion_list => $suggestion_list,
        );
    } else {
        set_status($status, 'invalid', "Could not clear history: $err");
    }
});

$run_btn->signal_connect(clicked => sub {
    run_current_command(
        entry   => $entry,
        run_btn => $run_btn,
        status  => $status,
        window  => $window,
    );
});

$window->show_all;
$entry->grab_focus;
refresh_ui(
    entry           => $entry,
    run_btn         => $run_btn,
    status          => $status,
    suggestion_list => $suggestion_list,
);
Gtk3::main();
exit 0;

sub usage {
    return <<'USAGE';
neofelis [--debug] [--no-history] [--clear-history] [--help]

  --debug          print diagnostics to stderr
  --no-history     do not load or save successful command history
  --clear-history  remove the saved history file and exit
  --help           show this help
USAGE
}

sub build_paths {
    my $home = $ENV{HOME} // '.';

    my $xdg_state  = $ENV{XDG_STATE_HOME}  || File::Spec->catdir($home, '.local', 'state');
    my $xdg_config = $ENV{XDG_CONFIG_HOME} || File::Spec->catdir($home, '.config');

    my $state_dir = File::Spec->catdir($xdg_state,  'neofelis');
    my $config_dir = File::Spec->catdir($xdg_config, 'neofelis');

    return (
        state_dir    => $state_dir,
        config_dir   => $config_dir,
        history_file => File::Spec->catfile($state_dir,  'history'),
        config_file  => File::Spec->catfile($config_dir, 'config'),
    );
}

sub refresh_ui {
    my (%args) = @_;
    my $entry           = $args{entry};
    my $run_btn         = $args{run_btn};
    my $status          = $args{status};
    my $suggestion_list = $args{suggestion_list};
    my $text = $entry->get_text;

    my $result = validate_input($text);
    $APP{suggestions} = build_suggestions($text, $APP{history}, $MAX_SUGGESTIONS);
    refill_suggestion_list($suggestion_list, $APP{suggestions});

    $run_btn->set_sensitive($result->{ok} ? TRUE : FALSE);

    if ($APP{history_warning} && !$text) {
        set_status($status, $APP{history_parse_failed} ? 'invalid' : 'neutral', $APP{history_warning});
        return;
    }

    my %messages = (
        empty                 => 'Type a command. Run stays disabled until the input is runnable.',
        invalid_syntax        => 'Shell syntax is incomplete or broken.',
        invalid_path          => 'The referenced path does not exist or is not executable.',
        unresolved_executable => 'The first command token is not an executable found in PATH.',
        valid_direct          => 'Ready to launch as a direct executable invocation.',
        valid_shell           => 'Ready to launch through /bin/sh -c after syntax validation.',
    );

    my $kind = $result->{ok} ? 'valid' : ($result->{state} eq 'empty' ? 'neutral' : 'invalid');
    set_status($status, $kind, $messages{$result->{state}} // '');
}

sub set_status {
    my ($label, $kind, $message) = @_;
    my $ctx = $label->get_style_context;
    $ctx->remove_class('status-valid');
    $ctx->remove_class('status-invalid');
    $ctx->remove_class('status-neutral');
    $ctx->add_class('status-' . $kind);
    $label->set_text($message // '');
}

sub validate_input {
    my ($text) = @_;
    $text = '' unless defined $text;

    if (defined $APP{validation_text} && $APP{validation_text} eq $text) {
        return $APP{validation_result};
    }

    my $trimmed = $text;
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+\z//;

    my $result;

    if ($trimmed eq '') {
        $result = { ok => 0, state => 'empty', mode => 'none' };
    }
    elsif ($trimmed =~ /\0/) {
        $result = { ok => 0, state => 'invalid_syntax', mode => 'none' };
    }
    elsif (looks_shellish($trimmed)) {
        if (shell_syntax_ok($trimmed)) {
            $result = { ok => 1, state => 'valid_shell', mode => 'shell' };
        } else {
            $result = { ok => 0, state => 'invalid_syntax', mode => 'shell' };
        }
    }
    else {
        my ($first) = split /\s+/, $trimmed, 2;
        my $resolved = resolve_executable($first);
        if ($resolved->{ok}) {
            my @argv = split /\s+/, $trimmed;
            $result = {
                ok    => 1,
                state => 'valid_direct',
                mode  => 'direct',
                argv  => \@argv,
                exec  => $resolved->{path},
            };
        }
        else {
            $result = {
                ok    => 0,
                state => $resolved->{state},
                mode  => 'direct',
            };
        }
    }

    $APP{validation_text}   = $text;
    $APP{validation_result} = $result;
    return $result;
}

sub looks_shellish {
    my ($text) = @_;
    return 1 if $text =~ /^\s*(?:[A-Za-z_][A-Za-z0-9_]*=)/;

    my ($first) = split /\s+/, trim($text), 2;
    return 1 if defined($first) && $first =~ /^(?:\.|:|break|cd|command|continue|eval|exec|exit|export|readonly|return|set|shift|times|trap|umask|unset|wait|if|then|else|elif|fi|for|while|until|do|done|case|esac|in)$/;

    return $text =~ /["'`\\|&;<>!\(\)\$\*\?\{\}\[\]~\n]/ ? 1 : 0;
}

sub shell_syntax_ok {
    my ($cmd) = @_;
    my $rc = system('/bin/sh', '-n', '-c', $cmd);
    if ($rc == -1) {
        debug_log("syntax check failed to start: $!");
        return 0;
    }
    return (($rc >> 8) == 0) ? 1 : 0;
}

sub resolve_executable {
    my ($first) = @_;
    return { ok => 0, state => 'unresolved_executable' } if !defined($first) || $first eq '';

    if ($first =~ m{/}) {
        return { ok => 0, state => 'invalid_path' } unless -e $first;
        return { ok => 0, state => 'invalid_path' } unless -f _;
        return { ok => 1, path => $first, state => 'valid_direct' } if -x _;
        return { ok => 0, state => 'invalid_path' };
    }

    my $path = $ENV{PATH} // '';
    for my $dir (split /:/, $path) {
        $dir = '.' if !defined($dir) || $dir eq '';
        my $candidate = File::Spec->catfile($dir, $first);
        next unless -e $candidate;
        next unless -f _;
        next unless -x _;
        return { ok => 1, path => $candidate, state => 'valid_direct' };
    }

    return { ok => 0, state => 'unresolved_executable' };
}

sub build_suggestions {
    my ($input, $history, $limit) = @_;
    $limit ||= 6;
    $history ||= [];

    my $trimmed = $input // '';
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+\z//;

    my @prefix;
    my @substring;
    my %seen;

    for my $cmd (@$history) {
        next if !defined($cmd) || $cmd eq '';
        next if $seen{$cmd}++;
        if ($trimmed eq '') {
            push @prefix, $cmd;
            next;
        }
        my $lhs = lc $cmd;
        my $rhs = lc $trimmed;
        if (index($lhs, $rhs) == 0) {
            push @prefix, $cmd;
        }
        elsif (index($lhs, $rhs) >= 0) {
            push @substring, $cmd;
        }
    }

    my @out = (@prefix, @substring);
    splice @out, $limit if @out > $limit;
    return \@out;
}

sub refill_suggestion_list {
    my ($list, $suggestions) = @_;
    for my $child ($list->get_children) {
        $list->remove($child);
    }

    for my $cmd (@{$suggestions || []}) {
        my $row = Gtk3::ListBoxRow->new();
        my $box = Gtk3::Box->new('horizontal', 0);
        $box->set_border_width(8);
        my $label = Gtk3::Label->new($cmd);
        $label->set_xalign(0.0);
        $label->set_ellipsize('end');
        $label->get_style_context->add_class('suggestion-label');
        $box->pack_start($label, TRUE, TRUE, 0);
        $row->add($box);
        $row->set_selectable(TRUE);
        $row->set_activatable(TRUE);
        $row->set_can_focus(TRUE);
        $list->add($row);
    }

    if (@{$suggestions || []}) {
        $list->show_all;
        $list->get_parent->get_parent->show;
    }
    else {
        $list->get_parent->get_parent->hide;
    }
}

sub apply_suggestion_row {
    my ($entry, $row) = @_;
    return unless $row;
    my $box = $row->get_child;
    return unless $box;
    my @children = $box->get_children;
    my $label = $children[0] or return;
    my $value = $label->get_text;
    return unless defined $value;
    $entry->set_text($value);
    $entry->set_position(length($value));
    $entry->grab_focus;
}

sub current_completion {
    my ($text, $suggestions) = @_;
    my $trimmed = $text // '';
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+\z//;
    return undef if $trimmed eq '';

    for my $candidate (@{$suggestions || []}) {
        return $candidate if index(lc($candidate), lc($trimmed)) == 0 && lc($candidate) ne lc($trimmed);
    }
    return undef;
}

sub run_current_command {
    my (%args) = @_;
    my $entry  = $args{entry};
    my $status = $args{status};
    my $window = $args{window};
    my $text   = $entry->get_text;
    my $result = validate_input($text);

    unless ($result->{ok}) {
        return;
    }

    my $spawn = spawn_detached($text, $result);
    unless ($spawn->{ok}) {
        set_status($status, 'invalid', "Launch failed: $spawn->{error}");
        return;
    }

    unless ($OPT{no_history} || $APP{history_parse_failed}) {
        update_history_in_memory($APP{history}, $text, $MAX_HISTORY);
        my ($ok, $err) = save_history($PATHS{state_dir}, $PATHS{history_file}, $APP{history});
        if (!$ok) {
            debug_log("history save failed: $err");
        }
    }

    $window->destroy;
    Gtk3::main_quit();
}

sub spawn_detached {
    my ($command, $validation) = @_;

    pipe(my $reader, my $writer) or return { ok => 0, error => "pipe failed: $!" };
    fcntl($writer, F_SETFD, FD_CLOEXEC);

    my $pid = fork();
    if (!defined $pid) {
        close $reader;
        close $writer;
        return { ok => 0, error => "fork failed: $!" };
    }

    if ($pid == 0) {
        close $reader;

        POSIX::setsid() or child_fail($writer, "setsid failed: $!");

        my $pid2 = fork();
        if (!defined $pid2) {
            child_fail($writer, "second fork failed: $!");
        }
        if ($pid2 > 0) {
            close $writer;
            POSIX::_exit(0);
        }

        open(STDIN,  '<', '/dev/null') or child_fail($writer, "redirect stdin failed: $!");
        open(STDOUT, '>', '/dev/null') or child_fail($writer, "redirect stdout failed: $!");
        open(STDERR, '>', '/dev/null') or child_fail($writer, "redirect stderr failed: $!");

        close_extra_fds(fileno($writer));

        if (($validation->{mode} || '') eq 'direct') {
            my @argv = split /\s+/, trim($command);
            exec { $validation->{exec} } @argv;
            child_fail($writer, "exec failed: $!");
        }
        else {
            exec { '/bin/sh' } '/bin/sh', '-c', $command;
            child_fail($writer, "exec failed: $!");
        }
    }

    close $writer;
    waitpid($pid, 0);
    local $/;
    my $err = <$reader>;
    close $reader;

    if (defined $err && $err ne '') {
        chomp $err;
        return { ok => 0, error => $err };
    }
    return { ok => 1 };
}

sub child_fail {
    my ($writer, $msg) = @_;
    print {$writer} $msg, "\n";
    close $writer;
    POSIX::_exit(127);
}

sub close_extra_fds {
    my ($keep_fd) = @_;
    my $dir = '/proc/self/fd';
    return unless -d $dir;

    opendir(my $dh, $dir) or return;
    while (defined(my $name = readdir($dh))) {
        next if $name !~ /^\d+\z/;
        my $fd = int($name);
        next if $fd <= 2;
        next if defined $keep_fd && $fd == $keep_fd;
        eval { POSIX::close($fd); 1; };
    }
    closedir $dh;
}

sub load_history {
    my ($path, $limit) = @_;
    return ([], undef, 0) unless -e $path;

    open my $fh, '<:raw', $path
        or return ([], "History could not be read: $!", 0);

    local $/;
    my $raw = <$fh>;
    close $fh;

    my $decoded;
    eval {
        $decoded = decode('UTF-8', $raw, FB_CROAK);
        1;
    } or do {
        return ([], 'History exists but is not valid UTF-8. It was left untouched and auto-save is disabled for this session.', 1);
    };

    my @lines = grep { defined($_) && $_ ne '' } split /\n/, $decoded;
    my @history;
    my %seen;
    for my $cmd (reverse @lines) {
        next if $seen{$cmd}++;
        unshift @history, $cmd;
    }
    splice @history, $limit if @history > $limit;
    return (\@history, undef, 0);
}

sub update_history_in_memory {
    my ($history, $command, $limit) = @_;
    $command = trim($command);
    return if $command eq '';

    my @new = grep { $_ ne $command } @$history;
    unshift @new, $command;
    splice @new, $limit if @new > $limit;
    @$history = @new;
}

sub save_history {
    my ($state_dir, $path, $history) = @_;
    return (0, 'history unavailable') unless defined $history;

    my ($ok, $err) = ensure_private_dir($state_dir);
    return ($ok, $err) unless $ok;

    my $tmp = File::Spec->catfile($state_dir, '.history.tmp.' . $$ . '.' . time);
    my $payload = encode('UTF-8', join("\n", @$history) . (@$history ? "\n" : ''));

    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or return (0, "create temp file failed: $!");

    my $written = syswrite($fh, $payload);
    if (!defined $written || $written != length($payload)) {
        my $e = $! || 'short write';
        close $fh;
        unlink $tmp;
        return (0, "write failed: $e");
    }

    $fh->flush if $fh->can('flush');
    $fh->sync  if $fh->can('sync');
    close $fh or do {
        my $e = $!;
        unlink $tmp;
        return (0, "close failed: $e");
    };

    rename $tmp, $path or do {
        my $e = $!;
        unlink $tmp;
        return (0, "rename failed: $e");
    };

    chmod 0600, $path;
    sync_dir($state_dir);
    return (1, undef);
}

sub clear_history_file {
    my ($path) = @_;
    my ($ok, $err) = ensure_private_dir($PATHS{state_dir});
    return ($ok, $err) unless $ok;

    return save_history($PATHS{state_dir}, $path, []);
}

sub ensure_private_dir {
    my ($dir) = @_;
    if (!-d $dir) {
        make_path($dir, { mode => 0700 });
        return (0, "mkdir failed: $!") unless -d $dir;
    }
    chmod 0700, $dir;
    return (1, undef);
}

sub sync_dir {
    my ($dir) = @_;
    eval {
        sysopen(my $dh, $dir, O_RDONLY) or die;
        $dh->sync if $dh->can('sync');
        close $dh;
        1;
    };
}

sub trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

sub debug_log {
    my ($msg) = @_;
    return unless $OPT{debug};
    warn "neofelis: $msg\n";
}

sub install_css {
    my $provider = Gtk3::CssProvider->new;
    $provider->load_from_data(<<'CSS');
.root {
  background: @theme_base_color;
}
.title {
  font-size: 1.2rem;
  font-weight: 700;
}
.subtitle {
  opacity: 0.8;
}
.command-entry {
  min-height: 38px;
  padding: 6px;
}
.suggestions-wrap {
  border-radius: 8px;
}
.suggestion-label {
  font-family: monospace;
}
.status {
  min-height: 18px;
}
.status-valid {
  color: #2f7d32;
}
.status-invalid {
  color: #b3261e;
}
.status-neutral {
  color: #6b6b6b;
}
.secondary-button {
  min-width: 96px;
}
CSS
    Gtk3::StyleContext::add_provider_for_screen(
        Gtk3::Gdk::Screen::get_default(),
        $provider,
        600,
    );
}
__NEOFELIS_PERL__

    cat > "$STAGE_DIR/neofelis.desktop" <<'__NEOFELIS_DESKTOP__'
[Desktop Entry]
Type=Application
Name=Neofelis
Comment=Validated command launcher for Artix Linux
Exec=neofelis
Terminal=false
Categories=Utility;GTK;
StartupNotify=false
__NEOFELIS_DESKTOP__

    chmod 0755 "$STAGE_DIR/neofelis"
    chmod 0644 "$STAGE_DIR/neofelis.desktop"
}

validate_payloads() {
    log "validating Perl syntax"
    perl -c "$STAGE_DIR/neofelis" >/dev/null 2>&1 || die "perl syntax check failed for staged neofelis"

    log "validating Gtk3 runtime module availability"
    perl -MGtk3 -e 1 >/dev/null 2>&1 || die "Perl Gtk3 module is not loadable after dependency installation"

    if command -v desktop-file-validate >/dev/null 2>&1; then
        log "validating desktop entry"
        desktop-file-validate "$STAGE_DIR/neofelis.desktop" >/dev/null 2>&1 || die "desktop entry validation failed"
    fi
}

backup_existing() {
    if [ -f "$INSTALL_BIN" ]; then
        cp -p "$INSTALL_BIN" "$BACKUP_DIR/neofelis.bin"
        HAD_OLD_BIN=1
    fi

    if [ -f "$INSTALL_DESKTOP" ]; then
        cp -p "$INSTALL_DESKTOP" "$BACKUP_DIR/neofelis.desktop"
        HAD_OLD_DESKTOP=1
    fi
}

atomic_install_file() {
    src="$1"
    dst="$2"
    mode="$3"
    dst_dir=$(dirname "$dst")
    base=${dst##*/}
    tmp_dst="$dst_dir/.${base}.neofelis.new.$$"

    mkdir -p "$dst_dir"
    install -m "$mode" "$src" "$tmp_dst"
    mv -f "$tmp_dst" "$dst"
}

install_payloads() {
    log "installing files atomically"
    backup_existing

    atomic_install_file "$STAGE_DIR/neofelis" "$INSTALL_BIN" 0755
    atomic_install_file "$STAGE_DIR/neofelis.desktop" "$INSTALL_DESKTOP" 0644
}

post_install() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        log "updating desktop database"
        update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || warn "desktop database update failed"
    fi

    log "verifying installed executable"
    "$INSTALL_BIN" --help >/dev/null 2>&1 || die "installed neofelis did not pass smoke test"
}

main() {
    require_cmd awk
    require_cmd cat
    require_cmd chmod
    require_cmd cp
    require_cmd id
    require_cmd install
    require_cmd mktemp
    require_cmd mv
    require_cmd pacman
    require_cmd rm
    require_cmd uname

    assert_target_system
    assert_root
    make_workspace
    install_dependencies
    write_payloads
    validate_payloads
    install_payloads
    post_install

    INSTALL_OK=1

    log "installation completed successfully"
    log "installed executable: $INSTALL_BIN"
    log "installed desktop entry: $INSTALL_DESKTOP"
    log "run it as a regular user with: neofelis"
}

main "$@"
