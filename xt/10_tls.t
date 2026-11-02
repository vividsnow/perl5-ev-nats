use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use POSIX ();
use lib 'xt/lib';
use EVNatsHelpers qw(
    nats_bin_or_skip
    free_port
    spawn_nats
    wait_for_port
    stop_nats
);
use EV;
use EV::Nats;

plan skip_all => 'EV::Nats built without TLS' unless EV::Nats::HAS_TLS();

my $nats_bin = nats_bin_or_skip();
my $openssl = `which openssl 2>/dev/null`;
chomp $openssl;
plan skip_all => 'openssl command not found' unless -x $openssl;

my $tmp = tempdir(CLEANUP => 1);
my @pids;
END { stop_nats($_) for grep { $_ } @pids }

sub run_cmd {
    my (@cmd) = @_;
    my $pid = fork;
    die "fork @cmd: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', File::Spec->devnull;
        open STDERR, '>', File::Spec->devnull;
        { exec @cmd }
        POSIX::_exit(127);
    }
    waitpid $pid, 0;
    my $status = $?;
    die "@cmd failed with status " . ($status >> 8) if $status;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} $content;
    close $fh or die "close $path: $!";
}

sub issue_certificates {
    my $ca_key = "$tmp/ca.key";
    my $ca_pem = "$tmp/ca.pem";
    my $server_key = "$tmp/server.key";
    my $server_csr = "$tmp/server.csr";
    my $server_pem = "$tmp/server.pem";
    my $server_ext = "$tmp/server.ext";
    my $client_key = "$tmp/client.key";
    my $client_csr = "$tmp/client.csr";
    my $client_pem = "$tmp/client.pem";
    my $client_ext = "$tmp/client.ext";
    my $wrong_key = "$tmp/wrong.key";
    my $encrypted_key = "$tmp/encrypted.key";

    run_cmd($openssl, qw(req -x509 -newkey rsa:2048 -nodes -days 1),
            '-subj', '/CN=EV Nats Test CA',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
            '-keyout', $ca_key, '-out', $ca_pem);

    write_file($server_ext, <<'EXT');
[server]
subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EXT
    run_cmd($openssl, qw(req -new -newkey rsa:2048 -nodes),
            '-subj', '/CN=localhost',
            '-keyout', $server_key, '-out', $server_csr);
    run_cmd($openssl, qw(x509 -req -days 1),
            '-in', $server_csr, '-CA', $ca_pem, '-CAkey', $ca_key,
            '-CAcreateserial', '-extfile', $server_ext, '-extensions', 'server',
            '-out', $server_pem);

    write_file($client_ext, <<'EXT');
[client]
extendedKeyUsage=clientAuth
keyUsage=digitalSignature
EXT
    run_cmd($openssl, qw(req -new -newkey rsa:2048 -nodes),
            '-subj', '/CN=ev-nats-client',
            '-keyout', $client_key, '-out', $client_csr);
    run_cmd($openssl, qw(x509 -req -days 1),
            '-in', $client_csr, '-CA', $ca_pem, '-CAkey', $ca_key,
            '-CAcreateserial', '-extfile', $client_ext, '-extensions', 'client',
            '-out', $client_pem);
    run_cmd($openssl, qw(genpkey -algorithm RSA),
            '-pkeyopt', 'rsa_keygen_bits:2048', '-out', $wrong_key);
    run_cmd($openssl, qw(genpkey -algorithm RSA -aes-256-cbc),
            '-pass', 'pass:test-password',
            '-pkeyopt', 'rsa_keygen_bits:2048', '-out', $encrypted_key);

    return {
        ca         => $ca_pem,
        server_cert => $server_pem,
        server_key  => $server_key,
        client_cert => $client_pem,
        client_key  => $client_key,
        wrong_key   => $wrong_key,
        encrypted_key => $encrypted_key,
    };
}

my $cert = issue_certificates();

sub start_tls_server {
    my (%opt) = @_;
    my $port = $opt{port} || free_port();
    my $conf = "$tmp/nats-$port.conf";
    my $verify = $opt{verify} ? "  ca_file: \"$cert->{ca}\"\n  verify: true\n" : '';
    my $first = $opt{handshake_first} ? "  handshake_first: true\n" : '';
    write_file($conf, <<"CONF");
listen: 127.0.0.1:$port
tls {
  cert_file: "$cert->{server_cert}"
  key_file: "$cert->{server_key}"
$verify$first}
CONF
    my $pid = spawn_nats($nats_bin, '-c', $conf,
                         '-l', "$tmp/nats-$port.log");
    push @pids, $pid;
    die "nats-server did not listen on $port"
        unless wait_for_port('127.0.0.1', $port, 5);
    return ($pid, $port);
}

sub forget_pid {
    my ($pid) = @_;
    @pids = grep { $_ != $pid } @pids;
}

sub stop_server {
    my ($pid) = @_;
    stop_nats($pid);
    forget_pid($pid);
}

sub connect_result {
    my (%opt) = @_;
    my ($connected, $err) = (0, undef);
    my $nats;
    $nats = EV::Nats->new(
        host => '127.0.0.1',
        connect_timeout => 3000,
        reconnect => 0,
        %opt,
        on_connect => sub { $connected = 1; EV::break },
        on_error   => sub { $err = $_[0]; EV::break },
    );
    my $guard = EV::timer 5, 0, sub {
        $err ||= 'test timeout';
        EV::break;
    };
    EV::run;
    return ($nats, $connected, $err);
}

sub pubsub_roundtrip {
    my ($nats, $subject, $payload) = @_;
    my $got;
    $nats->subscribe($subject, sub { $got = $_[1]; EV::break });
    $nats->publish($subject, $payload);
    my $guard = EV::timer 3, 0, sub { EV::break };
    EV::run;
    return $got;
}

subtest 'TLS configuration API' => sub {
    my $nats = EV::Nats->new;
    is $nats->tls_handshake_first, 0, 'TLS-first disabled by default';
    $nats->tls_handshake_first(1);
    is $nats->tls_handshake_first, 1, 'TLS-first setter enables the mode';
    $nats->tls_client_cert($cert->{client_cert}, $cert->{client_key});
    pass 'client certificate setter accepts a complete pair';

    eval { EV::Nats->new(tls_cert_file => $cert->{client_cert}) };
    like $@, qr/tls_cert_file and tls_key_file must both be non-empty/,
        'constructor rejects a missing key';
    eval { $nats->tls_client_cert('', $cert->{client_key}) };
    like $@, qr/certificate and key must both be non-empty/,
        'setter rejects an incomplete pair';
};

subtest 'existing INFO-first TLS path' => sub {
    my ($pid, $port) = start_tls_server();
    my ($nats, $connected, $err) = connect_result(
        port => $port, tls => 1, tls_ca_file => $cert->{ca},
    );
    ok $connected, 'TLS connection with CA succeeds' or diag($err // '');
    is pubsub_roundtrip($nats, 'tls.info.echo', 'hello-info'),
        'hello-info', 'INFO-first TLS pub/sub works';
    eval { $nats->tls(0) };
    like $@, qr/cannot change TLS configuration while connection is active/,
        'legacy TLS setter rejects active connection changes';
    $nats->disconnect if $connected;

    my ($skip, $skip_connected) = connect_result(
        port => $port, tls => 1, tls_skip_verify => 1,
    );
    ok $skip_connected, 'tls_skip_verify still connects without CA';
    $skip->disconnect if $skip_connected;
    stop_server($pid);
};

subtest 'strict TLS handshake first' => sub {
    my ($pid, $port) = start_tls_server(handshake_first => 1);
    my ($nats, $connected, $err) = connect_result(
        port => $port,
        tls_handshake_first => 1,
        tls_ca_file => $cert->{ca},
    );
    ok $connected, 'TLS-first connection succeeds' or diag($err // '');
    is pubsub_roundtrip($nats, 'tls.first.echo', 'hello-first'),
        'hello-first', 'TLS-first pub/sub works';
    $nats->disconnect if $connected;
    stop_server($pid);

    ($pid, $port) = start_tls_server();
    (undef, $connected, $err) = connect_result(
        port => $port,
        tls_handshake_first => 1,
        tls_ca_file => $cert->{ca},
    );
    ok !$connected, 'TLS-first does not fall back to INFO-first';
    like $err, qr/SSL handshake failed/i, 'mode mismatch reports TLS failure';
    stop_server($pid);
};

subtest 'mTLS client certificates' => sub {
    my ($pid, $port) = start_tls_server(verify => 1);
    my ($missing, $connected, $err) = connect_result(
        port => $port, tls => 1, tls_ca_file => $cert->{ca},
    );
    ok !$connected, 'mTLS server rejects a client without a certificate';
    ok defined($err) || !$missing->is_connected,
        'missing client certificate does not become connected';

    my ($nats, $valid, $valid_err) = connect_result(
        port => $port,
        tls_ca_file => $cert->{ca},
        tls_cert_file => $cert->{client_cert},
        tls_key_file => $cert->{client_key},
    );
    ok $valid, 'valid client certificate and key connect'
        or diag($valid_err // '');
    is pubsub_roundtrip($nats, 'tls.mtls.echo', 'hello-mtls'),
        'hello-mtls', 'mTLS pub/sub works';
    $nats->disconnect if $valid;

    my (undef, $wrong, $wrong_err) = connect_result(
        port => $port,
        tls_ca_file => $cert->{ca},
        tls_cert_file => $cert->{client_cert},
        tls_key_file => $cert->{wrong_key},
    );
    ok !$wrong, 'mismatched client key is rejected';
    like $wrong_err, qr/certificate\/key mismatch/i,
        'mismatched key reports a clear setup error';

    my (undef, $encrypted, $encrypted_err) = connect_result(
        port => $port,
        tls_ca_file => $cert->{ca},
        tls_cert_file => $cert->{client_cert},
        tls_key_file => $cert->{encrypted_key},
    );
    ok !$encrypted, 'password-protected client key is rejected';
    like $encrypted_err, qr/client key load failed/i,
        'encrypted key fails without an interactive password prompt';
    stop_server($pid);
};

subtest 'TLS-first and mTLS combine and reconnect' => sub {
    my $port = free_port();
    my ($pid) = start_tls_server(
        port => $port, verify => 1, handshake_first => 1,
    );
    my ($connects, $err) = (0, undef);
    my ($restart, $guard);
    my $nats;
    $nats = EV::Nats->new(
        host => '127.0.0.1',
        port => $port,
        tls_handshake_first => 1,
        tls_ca_file => $cert->{ca},
        tls_cert_file => $cert->{client_cert},
        tls_key_file => $cert->{client_key},
        reconnect => 1,
        reconnect_delay => 100,
        max_reconnect_delay => 200,
        max_reconnect_attempts => 30,
        connect_timeout => 2000,
        on_error => sub { $err = $_[0] unless $_[0] =~ /connection refused/i },
        on_connect => sub {
            $connects++;
            if ($connects == 1) {
                $restart = EV::timer 0.05, 0, sub {
                    undef $restart;
                    stop_server($pid);
                    ($pid) = start_tls_server(
                        port => $port, verify => 1, handshake_first => 1,
                    );
                };
            } else {
                EV::break;
            }
        },
    );
    $guard = EV::timer 12, 0, sub { EV::break };
    EV::run;
    is $connects, 2, 'TLS-first mTLS connection reconnects with the same identity'
        or diag($err // 'no error reported');
    $nats->disconnect;
    stop_server($pid);
};

done_testing;
