use strict;
use warnings;
use Test::More;
use MIME::Base64 qw(encode_base64 encode_base64url decode_base64);
use Digest::SHA qw(sha256 sha256_hex);
use JSON::PP ();
use EV::Nats::ObjectStore;
use EV::Nats::KV;

# Pure-Perl layer regressions (ObjectStore digest format, get() lifetime,
# clean misses, KV validation) against a mock JetStream. No socket at all.

# ---- mock JetStream: a tiny in-memory stream keyed by subject ----
# Acks are DEFERRED, like a real connection: on the live client js_publish
# goes through $nats->request and the ack arrives from the event loop, so
# put()'s publish loop always finishes before the first ack lands. A
# synchronous mock hides the real ordering bug this exercises.
{
    package MockJS;
    sub new {
        bless { store => {}, seq => 0, nats => MockConn->new, timeout => 100 }, shift;
    }
    sub js_publish {
        my ($self, $subj, $payload, $cb) = @_;
        $self->{store}{$subj} = { data => MIME::Base64::encode_base64($payload, ''),
                                  seq  => ++$self->{seq} };
        push @{ $self->{order} }, $subj;
        my $seq = $self->{seq};
        push @{ $self->{pending} }, sub { $cb->({ seq => $seq }, undef) };
    }
    sub drain {   # stand-in for the event loop
        my ($self) = @_;
        while (my $t = shift @{ $self->{pending} || [] }) { $t->() }
    }
    sub _json_api {
        my ($self, $subj, $body, $cb) = @_;
        if ($subj =~ /^STREAM\.MSG\.GET\./) {
            if (my $s = $body->{last_by_subj}) {
                my $m = $self->{store}{$s}
                    or return $cb->(undef, 'no message found (code 404)');
                return $cb->({ message => { %$m, subject => $s } }, undef);
            }
            if (my $s = $body->{next_by_subj}) {
                my $start = $body->{seq} || 1;
                for my $sub (@{ $self->{order} || [] }) {
                    next unless $sub eq $s;
                    my $m = $self->{store}{$sub};
                    next if $m->{seq} < $start;
                    return $cb->({ message => { %$m, subject => $sub } }, undef);
                }
                return $cb->(undef, 'no message found (code 404)');
            }
        }
        $cb->({}, undef);
    }
}
{
    package MockConn;
    sub new { bless {}, shift }
    sub new_inbox { '_INBOX.x.1' }
    sub subscribe { 1 }
    sub subscribe_max { 1 }
    sub unsubscribe { }
    sub hpublish { }
    sub flush { $_[1]->(undef) if $_[1] }
}
{
    # DESTROY runs the callback it holds: proves the ObjectStore it rode in
    # on was really freed. (Note it must own a fresh referent -- blessing a
    # ref to the caller's flag would bless the FLAG, whose lifetime has
    # nothing to do with the ObjectStore's.)
    package Guard;
    sub new { my ($class, $cb) = @_; bless { cb => $cb }, $class }
    sub DESTROY { $_[0]{cb}->() }
}

sub rewrite_digest {
    my ($js, $meta_subj, $replacement) = @_;
    my $j = decode_base64($js->{store}{$meta_subj}{data});
    $j =~ s/SHA-256=[^"]+/$replacement/;
    $js->{store}{$meta_subj}{data} = encode_base64($j, '');
}

subtest 'ObjectStore digest is base64url, legacy hex verifies, corrupt rejected' => sub {
    plan tests => 7;
    my $js = MockJS->new;
    my $os = EV::Nats::ObjectStore->new(js => $js, bucket => 'B');
    my $data = 'hello object store' x 10;
    $os->put('thing', $data, sub { });
    $js->drain;
    my ($meta_subj) = grep { /\.M\./ } keys %{ $js->{store} };
    my $meta = JSON::PP::decode_json(decode_base64($js->{store}{$meta_subj}{data}));

    is $meta->{digest}, 'SHA-256=' . encode_base64url(sha256($data)),
       'put writes SHA-256=<base64url of raw digest>';
    unlike $meta->{digest}, qr/\ASHA-256=[0-9a-f]{64}\z/, 'digest is not legacy hex';

    my $got;
    $os->get('thing', sub { $got = [ @_ ] });
    is $got->[0], $data, 'round-trip get returns the data';
    is $got->[1], undef, 'new digest verifies (no error)';

    # Buckets written by 0.03/0.04 carry hex; they must still verify.
    rewrite_digest($js, $meta_subj, 'SHA-256=' . sha256_hex($data));
    undef $got;
    $os->get('thing', sub { $got = [ @_ ] });
    is $got->[0], $data, 'legacy hex digest returns the data';
    is $got->[1], undef, 'legacy hex digest verifies (no error)';

    # A genuinely corrupt digest must still be caught.
    rewrite_digest($js, $meta_subj, 'SHA-256=deadbeef');
    undef $got;
    $os->get('thing', sub { $got = [ @_ ] });
    like $got->[1], qr/digest mismatch/, 'corrupt digest still rejected';
};

subtest 'get() does not pin the connection' => sub {
    plan tests => 2;
    my $destroyed = 0;
    my $r;
    {
        my $js = MockJS->new;
        my $os = EV::Nats::ObjectStore->new(js => $js, bucket => 'B');
        # rides along inside the $self that get()'s closure captures
        $os->{_guard} = Guard->new(sub { $destroyed = 1 });
        $os->put('g', 'payload', sub { });
        $js->drain;
        $os->get('g', sub { $r = [ @_ ] });
        is $r->[0], 'payload', 'get returned data';
    }
    ok $destroyed, 'ObjectStore freed after get() (callback cycle broken)';
};

subtest 'missing object is a clean miss' => sub {
    plan tests => 2;
    my $js = MockJS->new;
    my $os = EV::Nats::ObjectStore->new(js => $js, bucket => 'B');
    my $got;
    $os->get('nope', sub { $got = [ @_ ] });
    is $got->[0], undef, 'get(missing) returns no data';
    is $got->[1], undef, 'get(missing) returns no error';
};

subtest 'KV key and bucket validation' => sub {
    plan tests => 12;
    my $js = MockJS->new;
    ok !eval { EV::Nats::KV->new(js => $js, bucket => 'bad bucket'); 1 },
       'bucket with a space rejected';
    my $kv = eval { EV::Nats::KV->new(js => $js, bucket => 'good-bucket_1') };
    ok $kv, 'valid bucket accepted';
    for my $bad ('a b', 'a>b', 'a*b', '.lead', 'trail.', "nl\nkey") {
        (my $show = $bad) =~ s/\n/\\n/;
        ok !eval { $kv->get($bad, sub { }); 1 }, "key '$show' rejected";
    }
    for my $good ('a.b.c', 'A_b-c', 'x=1', 'path/to/key') {
        ok eval { $kv->get($good, sub { }); 1 }, "key '$good' accepted"
            or diag $@;
    }
};

done_testing;
