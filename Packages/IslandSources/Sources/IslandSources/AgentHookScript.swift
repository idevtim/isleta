import Foundation

/// The one command Isleta registers in a coding agent's hooks, and where it lives.
///
/// # Why a Perl script
///
/// It runs on **every** permission prompt, in the agent's own process tree and on its clock, so it
/// has to start in milliseconds and need nothing installed. `/usr/bin/perl` ships with macOS and is
/// already the interpreter Now Playing runs under (`NowPlayingAdapterProvider`); `IO::Socket::UNIX`
/// and `JSON::PP` are both in its core library. Launching Isleta's own binary instead would load
/// AppKit per prompt, and a shell script has no way to wait for one line back on a Unix socket
/// without leaning on `nc` flags that differ between releases.
///
/// # What it promises the agent
///
/// - **It always exits 0 and prints nothing unless Isleta answered.** Isleta not running, mid-update,
///   or never installed past this file: the connect fails and the agent carries on as if the hook
///   were not there — no "hook error" in the session and no change to its permission flow.
/// - **A decision only goes back on the connection that asked**, so one session can never be
///   answered with another's click.
/// - **It never sends `updatedPermissions`.** Allowing from the island allows this one call; every
///   rule change still happens in the agent.
/// - **It changes a tool's input in one way only:** the `answers` to a question the agent asked
///   (`AskUserQuestion`), merged into the input the agent sent, one for every question it asked. The
///   agent reads that as the person having chosen in its own picker (measured — see
///   `docs/PLATFORM-CONSTRAINTS.md`).
/// - **It trims before it sends.** A Write tool's input is the whole file; the island needs a line.
///   What crosses the socket is the event name, the session id, the tool's name, one summary line
///   and the command, cut to length — and it is shown on screen and never logged.
///
/// The path is stable on purpose (`installedURL`): the agent's settings name it, and an app that
/// moved or updated must not leave a dead command behind. The script is rewritten from this string
/// on every install, so the copy on disk is always this build's.
public enum AgentHookScript {

    /// `~/Library/Application Support/Isleta`. Created `0700`, because the socket inside it is the
    /// door a permission answer comes through.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Isleta", isDirectory: true)
    }

    public static var installedURL: URL { directory.appendingPathComponent("agent-hook.pl") }

    public static var socketURL: URL { directory.appendingPathComponent("agent.sock") }

    /// How long an agent lets the hook hold a permission prompt. Long on purpose: the prompt is on
    /// screen in the terminal the whole time (measured — see `docs/PLATFORM-CONSTRAINTS.md`), so the
    /// hook waiting costs the person nothing, and Isleta closes the connection the moment the
    /// session moves on. The number only matters if Isleta hangs.
    public static let timeoutSeconds = 3600

    /// The command line an agent's settings carry. Quoted, because the path has a space in it.
    public static func command(for agent: String) -> String {
        "'\(installedURL.path)' \(agent)"
    }

    /// Write the script, `0755`, into a `0700` directory.
    public static func install() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(source.utf8).write(to: installedURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedURL.path)
    }

    /// The script. `ISLETA_AGENT_SOCKET` overrides the socket path for the tests and for nothing else.
    static let source = #"""
    #!/usr/bin/perl
    # Isleta's coding-agent hook. Installed and rewritten by Isleta; editing it changes nothing for
    # long. Always exits 0, and prints a decision only when Isleta answered one.
    use strict;
    use warnings;
    use IO::Socket::UNIX;
    use JSON::PP;

    # Nothing on stderr either: an agent may surface it, and a connect that fails because Isleta is
    # not running is the ordinary case rather than an error.
    open STDERR, '>', '/dev/null';

    my $agent = $ARGV[0] // 'claudeCode';
    my $path = $ENV{ISLETA_AGENT_SOCKET}
        // "$ENV{HOME}/Library/Application Support/Isleta/agent.sock";

    my $raw = do { local $/; <STDIN> } // '';
    my $in = eval { JSON::PP->new->decode($raw) };
    exit 0 unless ref $in eq 'HASH';

    sub line {
        my ($value, $limit) = @_;
        return undef unless defined $value && !ref $value;
        $value =~ s/\s+/ /g;
        return length($value) > $limit ? substr($value, 0, $limit) : $value;
    }

    my $event = $in->{hook_event_name} // '';
    my $input = ref $in->{tool_input} eq 'HASH' ? $in->{tool_input} : {};
    my %out = (
        agent => $agent,
        event => $event,
        session_id => line($in->{session_id}, 200),
        tool_name => line($in->{tool_name}, 100),
        summary => line($input->{description} // $input->{file_path} // $input->{url}
            // $input->{pattern} // $input->{command}, 300),
        command => line($input->{command}, 1000),
        notification_type => line($in->{notification_type}, 100),
        agent_pid => getppid(),
        cwd => line($in->{cwd}, 1000),
    );

    # A question the agent is asking (`AskUserQuestion`): the questions and their option labels, so
    # the island can offer them as buttons. The options' descriptions stay behind — they are what
    # makes the terminal's picker tall, and the island has a line per option. More than the agent's
    # own limits (four questions, four options) sends none, and the island leaves it to the terminal
    # rather than answer part of it.
    my $asked = $input->{questions};
    if (ref $asked eq 'ARRAY' && @$asked && @$asked <= 4
        && !grep { ref $_ ne 'HASH' || ref $_->{options} ne 'ARRAY' || !@{$_->{options}} || @{$_->{options}} > 4 } @$asked) {
        $out{questions} = [map { {
            question => line($_->{question}, 400),
            header => line($_->{header}, 40),
            multi_select => $_->{multiSelect} ? JSON::PP::true : JSON::PP::false,
            options => [map { ref $_ eq 'HASH' ? line($_->{label}, 100) : undef } @{$_->{options}}],
        } } @$asked];
    }

    my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path) or exit 0;
    $socket->autoflush(1);
    print {$socket} JSON::PP->new->canonical->encode(\%out), "\n" or exit 0;
    exit 0 unless $event eq 'PermissionRequest';

    # Held until Isleta answers, or closes because the session moved on without it.
    my $reply = <$socket>;
    exit 0 unless defined $reply;
    $reply =~ s/\s+$//;
    my %decision = (
        allow => { behavior => 'allow' },
        deny => { behavior => 'deny', message => 'The person declined this from Isleta.' },
    );
    my $decision = $decision{$reply};

    # Answers to a question: `{"answers":["<label>","<label>, <label>"]}`, one per question in the
    # order they were asked. Isleta answers by position rather than by the question's text, because
    # the text it was sent was trimmed and the agent keys its answers by the text it wrote. They go
    # back as the tool's own input with `answers` filled in, which is what the agent's picker does
    # itself — so the call runs as if the person had chosen in the terminal. Every question has to
    # be answered, each with a string, or nothing is sent and the terminal keeps the question.
    if (!$decision && $reply =~ /^\{/ && ref $asked eq 'ARRAY') {
        my $parsed = eval { JSON::PP->new->decode($reply) };
        my $given = ref $parsed eq 'HASH' ? $parsed->{answers} : undef;
        exit 0 unless ref $given eq 'ARRAY' && @$given == @$asked;
        my %answers;
        for my $index (0 .. $#$asked) {
            my ($question, $value) = ($asked->[$index]{question}, $given->[$index]);
            exit 0 unless defined $question && !ref $question && defined $value && !ref $value
                && length $value;
            $answers{$question} = $value;
        }
        $decision = { behavior => 'allow', updatedInput => { %$input, answers => \%answers } };
    }
    exit 0 unless $decision;
    print JSON::PP->new->canonical->encode({
        hookSpecificOutput => {
            hookEventName => 'PermissionRequest',
            decision => $decision,
        },
    });
    exit 0;
    """#
}
