package Beekeeper::Logger;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Logger - Default logger used by worker processes.

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut

use constant LOG_EMERG  => 1;
use constant LOG_ALERT  => 2;
use constant LOG_CRIT   => 3;
use constant LOG_ERROR  => 4;
use constant LOG_WARN   => 5;
use constant LOG_NOTICE => 6;
use constant LOG_INFO   => 7;
use constant LOG_DEBUG  => 8;
use constant LOG_TRACE  => 9;

use JSON::XS;
use Exporter 'import';
use Time::HiRes;

our @EXPORT_OK = qw(
    LOG_EMERG
    LOG_ALERT
    LOG_CRIT
    LOG_ERROR
    LOG_WARN
    LOG_NOTICE
    LOG_INFO
    LOG_DEBUG
    LOG_TRACE
    %Label
);

our %EXPORT_TAGS = ('log_levels' => \@EXPORT_OK );

our %Label = (
    &LOG_EMERG  => 'emergency',
    &LOG_ALERT  => 'alert',
    &LOG_CRIT   => 'critical',
    &LOG_ERROR  => 'error',
    &LOG_WARN   => 'warning',
    &LOG_NOTICE => 'notice',
    &LOG_INFO   => 'info',
    &LOG_DEBUG  => 'debug',
    &LOG_TRACE  => 'trace',
);


sub new {
    my $class = shift;

    my $self = {
        worker_class => undef,
        stomp_conn   => undef,
        foreground   => undef,
        log_file     => undef,
        service      => undef,
        host         => undef,
        pool         => undef,
        @_
    };

    unless ($self->{service}) {
        # Make an educated guess based on worker class
        my $service = lc $self->{worker_class};
        $service =~ s/::/-/g;
        $service =~ s/-worker$//;

        $self->{service} = $service;
    }

    unless ($self->{log_file}) {
        # Use a single log file per service
        my $dir  = '/var/log';
        my $user = getpwuid($>);
        my $file = $self->{service} . '.log';
        ($user) = ($user =~ m/(\w+)/); # untaint

        $self->{log_file} = (-d "$dir/$user") ? "$dir/$user/$file" : "$dir/$file";
    }

    unless (1 || $self->{foreground}) {
        #
        my $log_file = $self->{log_file};

        if (open(my $fh, '>>', $log_file)) {
            # Send STDERR and STDOUT to log file
            open(STDERR, '>&', $fh) or die "Can't redirect STDERR to $log_file: $!";
            open(STDOUT, '>&', $fh) or die "Can't redirect STDOUT to $log_file: $!";
        }
        else {
            # Probably no permissions to open the log file
            warn "Can't open log file $log_file: $!";
        }
    }

    bless $self, $class;
    return $self; 
}

sub log {
    my ($self, $level, @msg) = @_;

    my $msg = join(' ', map { defined $_ ? "$_" : 'undef' } @msg );
    chomp($msg);

    my $now = Time::HiRes::time;
    my $ms = int(($now * 1000) % 1000);
    my @t = reverse((localtime)[0..5]); $t[0] += 1900; $t[1]++;
    my $tstamp = sprintf("%4d-%02d-%02d %02d:%02d:%02d.%03d", @t, $ms);

    ## 1. Log to local file

    print STDERR "[$tstamp][$$][$Label{$level}] $msg\n";

    ## 2. Log to topic

    my $bus = $self->{stomp_conn};
    return unless $bus && $bus->{is_connected};

    # JSON-RPC notification
    my $json = encode_json({
        jsonrpc => '2.0',
        method  => $Label{$level},
        params  => {
            level   => $level,
            service => $self->{service},
            host    => $self->{host},
            pool    => $self->{pool},
            pid     => $$,
            message => $msg,
            tstamp  => $now,
        }
    });

    $bus->send(
        'destination'  => "/topic/log.$level.$self->{service}",
      # 'content-type' => 'application/json;charset=utf-8',
        'body'         => \$json,
    );
}

1;

=head1 AUTHOR

José Micó, C<< <jose.mico@gmail.com> >>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by José Micó.

This is free software; you can redistribute it and/or modify it under the same 
terms as the Perl 5 programming language itself.

This software is distributed in the hope that it will be useful, but it is 
provided “as is” and without any express or implied warranties. For details, 
see the full text of the license in the file LICENSE.

=cut
