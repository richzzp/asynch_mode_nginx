#!/usr/bin/perl

# Copyright (C) Intel, Inc.
# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for stream ssl module with dynamic certificates.

###############################################################################

use warnings;
use strict;

use Test::More;

use Socket qw/ :DEFAULT CRLF /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval {
    require Net::SSLeay;
    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    Net::SSLeay::randomize();
};
plan(skip_all => 'Net::SSLeay not installed') if $@;

eval {
    my $ctx = Net::SSLeay::CTX_new() or die;
    my $ssl = Net::SSLeay::new($ctx) or die;
    Net::SSLeay::set_tlsext_host_name($ssl, 'example.org') == 1 or die;
};
plan(skip_all => 'Net::SSLeay with OpenSSL SNI support required') if $@;

my $t = Test::Nginx->new()->has(qw/stream stream_ssl stream_geo stream_return/)
    ->has_daemon('openssl');

$t->{_configure_args} =~ /OpenSSL ([\d\.]+)/;
plan(skip_all => 'OpenSSL too old') unless defined $1 and $1 ge '1.0.2';

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_HTTPS%%
    geo $one {
        default one;
    }

    geo $two {
        default two;
    }

    geo $pass {
        default pass;
    }

    ssl_session_cache shared:SSL:1m;
    ssl_session_tickets off;

    server {
        listen       127.0.0.1:8080 ssl;
        return       $ssl_server_name:$ssl_session_reused;
    %%TEST_GLOBALS_HTTPS%%
        ssl_certificate $one.crt;
        ssl_certificate_key $one.key;
    }

    server {
        listen       127.0.0.1:8083 ssl;
        return       $ssl_server_name:$ssl_session_reused;
    %%TEST_GLOBALS_HTTPS%%
        # found in key
        ssl_certificate pass.crt;
        ssl_certificate_key $pass.key;
        ssl_password_file password_file;
    }

    server {
        listen       127.0.0.1:8081 ssl;
        return       $ssl_server_name:$ssl_session_reused;
    %%TEST_GLOBALS_HTTPS%%
        ssl_certificate $one.crt;
        ssl_certificate_key $one.key;
    }

    server {
        listen       127.0.0.1:8082 ssl;
        return       $ssl_server_name:$ssl_session_reused;
    %%TEST_GLOBALS_HTTPS%%
        ssl_certificate $two.crt;
        ssl_certificate_key $two.key;
    }

    server {
        listen       127.0.0.1:8084 ssl;
        return       $ssl_server_name:$ssl_session_reused;
    %%TEST_GLOBALS_HTTPS%%
        ssl_certificate $ssl_server_name.crt;
        ssl_certificate_key $ssl_server_name.key;
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('one', 'two') {
    system('openssl req -x509 -new '
        . "-config $d/openssl.conf -subj /CN=$name/ "
        . "-out $d/$name.crt -keyout $d/$name.key "
        . ">>$d/openssl.out 2>&1") == 0
        or die "Can't create certificate for $name: $!\n";
}

foreach my $name ('pass') {
    system("openssl genrsa -out $d/$name.key -passout pass:pass "
        . "-aes128 2048 >>$d/openssl.out 2>&1") == 0
        or die "Can't create $name key: $!\n";
    system("openssl req -x509 -new -config $d/openssl.conf "
        . "-subj /CN=$name/ -out $d/$name.crt -key $d/$name.key "
        . "-passin pass:pass >>$d/openssl.out 2>&1") == 0
        or die "Can't create $name certificate: $!\n";
}

$t->write_file('password_file', 'pass');
$t->write_file('index.html', '');

$t->try_run('no ssl_certificate variables')->plan(7);

###############################################################################

like(cert('default', 8080), qr/CN=one/, 'default certificate');
like(get('default', 8080), qr/default/, 'default context');

like(get('password', 8083), qr/password/, 'ssl_password_file');

# session reuse

my ($s, $ssl) = get_ssl_socket('default', 8080);
my $ses = Net::SSLeay::get_session($ssl);

like(get('default', 8080, $ses), qr/:r/, 'session reused');

# do not check $ssl_server_name, since stream doesn't install SNI callback
# see for more details: https://github.com/openssl/openssl/issues/7014

like(get('default', 8081, $ses), qr/:r/, 'session id context match');
like(get('default', 8082, $ses), qr/:\./, 'session id context distinct');

# errors

Net::SSLeay::ERR_clear_error();
get_ssl_socket('nx', 8084);
ok(Net::SSLeay::ERR_peek_error(), 'no certificate');

###############################################################################

sub get {
    my ($host, $port, $ctx) = @_;
    my ($s, $ssl) = get_ssl_socket($host, $port, $ctx) or return;
    my $r = Net::SSLeay::read($ssl);
    $s->close();
    return $r;
}

sub cert {
    my ($host, $port, $ctx) = @_;
    my ($s, $ssl) = get_ssl_socket($host, $port, $ctx) or return;
    Net::SSLeay::dump_peer_certificate($ssl);
}

sub get_ssl_socket {
    my ($host, $port, $ses) = @_;
    my $s;

    my $dest_ip = inet_aton('127.0.0.1');
    $port = port($port);
    my $dest_serv_params = sockaddr_in($port, $dest_ip);

    socket($s, &AF_INET, &SOCK_STREAM, 0) or die "socket: $!";
    connect($s, $dest_serv_params) or die "connect: $!";

    my $ctx = Net::SSLeay::CTX_new() or die("Failed to create SSL_CTX $!");
    my $ssl = Net::SSLeay::new($ctx) or die("Failed to create SSL $!");
    Net::SSLeay::set_tlsext_host_name($ssl, $host);
    Net::SSLeay::set_session($ssl, $ses) if defined $ses;
    Net::SSLeay::set_fd($ssl, fileno($s));
    Net::SSLeay::connect($ssl) or die("ssl connect");
    return ($s, $ssl);
}

###############################################################################
