#!/usr/bin/env perl
# TLS connection example
# Requires: nats-server with TLS configured
use strict;
use warnings;
use EV;
use EV::Nats;

my $nats;
$nats = EV::Nats->new(
    host            => $ENV{NATS_HOST} // '127.0.0.1',
    port            => $ENV{NATS_PORT} // 4222,
    tls             => 1,
    tls_ca_file     => $ENV{NATS_CA_FILE},      # optional, uses system CAs if omitted
    tls_skip_verify => $ENV{NATS_SKIP_VERIFY},   # for self-signed certs
    tls_handshake_first => $ENV{NATS_TLS_FIRST}, # server handshake_first: true
    tls_cert_file   => $ENV{NATS_CERT_FILE},     # both required for mTLS
    tls_key_file    => $ENV{NATS_KEY_FILE},      # unencrypted PEM key
    on_error   => sub { warn "error: @_\n" },
    on_connect => sub {
        print "connected with TLS"
            . ($ENV{NATS_CERT_FILE} ? " and a client certificate" : "")
            . "\n";
        $nats->publish('tls.test', 'encrypted hello');
        $nats->flush(sub {
            print "message flushed\n";
            $nats->disconnect;
            EV::break;
        });
    },
);

EV::run;
