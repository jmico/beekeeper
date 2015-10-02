package Beekeeper::Worker::Util::SharedHash;

#TODO: rename SharedCache

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Worker::Util::SharedHash - ...

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

my $p = $self->shared_hash( ... );

=cut

use Fcntl qw(:DEFAULT :flock);
use JSON::XS;
use Carp;


sub new {
    my ($class, %args) = @_;

    my $worker = $args{'worker'};
    my $id     = $args{'id'};

    my $self = {
        _BUS      => $worker->{_BUS},
        id        => $id,
        uid       => int(rand(90000000)+10000000),
        resolver  => $args{'resolver'},
        on_update => $args{'on_update'},
        persist   => $args{'persist'},
        max_age   => $args{'max_age'},
        synced    => 0,
        data      => {},
        vers      => {},
        time      => {},
    };

    bless $self, $class;
    my $_self = $self;

    $self->_load_state if $self->{persist};

    $self->{_init} = $worker->do_async_job(
        method     => "_sync.$id.dump",
        _auth_     => '0,BKPR_SYSTEM',
        timeout    => 3,
        on_success => sub {
            $_self->_merge_dump(@_);
            $worker->accept_jobs("_sync.$id.dump" => sub { $_self->dump });
            delete $_self->{_init};
            $_self->{synced} = 1;
        },
        on_error => sub {
            $worker->accept_jobs("_sync.$id.dump" => sub { $_self->dump });
            delete $_self->{_init};
            $_self->{synced} = 1;
        }
    );

    my $local_bus = $self->{_BUS}->{bus_id};

    $self->{_BUS}->subscribe(
        destination    => "/topic/msg.$local_bus._sync.$id.set",
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;

            my $entry = decode_json($$body_ref);

            return if ($entry->[4] eq $_self->{uid});

            $_self->_merge($entry);
        }
    );

    if ($self->{max_age}) {
        $self->{gc_timer} = AnyEvent->timer(
            after    => rand( $self->{max_age} ), 
            interval => $self->{max_age},
            cb       => sub { $_self->_gc },
        );
    }

    return $self;
}

sub set {
    my ($self, $key, $value) = @_;

    croak "Key value is undefined" unless (defined $key);

    my $old = $self->{data}->{$key};

    $self->{data}->{$key} = $value;
    $self->{vers}->{$key}++;
    $self->{time}->{$key} = Time::HiRes::time();

    my $json = encode_json([
        $key,
        $value,
        $self->{vers}->{$key},
        $self->{time}->{$key},
        $self->{uid},
    ]);

    $self->{on_update}->($key, $value, $old) if $self->{on_update};

    my $id = $self->{id};
    my $local_bus = $self->{_BUS}->{bus_id};

    $self->{_BUS}->send(
        destination => "/topic/msg.$local_bus._sync.$id.set",
        body        => \$json,
    );

    unless (defined $value) {
        # Postpone delete because it is necessary to keep the versioning 
        # of this modification until it is propagated to all workers
        $self->{_destroy}->{$key} = AnyEvent->timer( after => 60, cb => sub {
            delete $self->{_destroy}->{$key};
            delete $self->{data}->{$key};
            delete $self->{vers}->{$key};
            delete $self->{time}->{$key};
        });
    }
}

sub get {
    my ($self, $key) = @_;

    $self->{data}->{$key};
}

sub delete {
    my ($self, $key) = @_;

    $self->set( $key => undef );
}

sub raw_data {
    my $self = shift;

    $self->{data};
}

sub _merge {
    my ($self, $entry) = @_;

    my ($key, $value, $version, $time) = @$entry;

    if ($version > ($self->{vers}->{$key} || 0)) {

        # Received a fresher value for the entry
        my $old = $self->{data}->{$key};

        $self->{data}->{$key} = $value;
        $self->{vers}->{$key} = $version;
        $self->{time}->{$key} = $time;

        $self->{on_update}->($key, $value, $old) if $self->{on_update};
    }
    elsif ($version < $self->{vers}->{$key}) {

        # Received a stale value (we have a newest version)
        return;
    }
    else {

        # Version conflict, default resolution is to keep newest value
        my $resolver = $self->{resolver} || sub {
            return $_[0]->{time} > $_[1]->{time} ? $_[0] : $_[1];
        };

        my $keep = $resolver->(
            {   # Mine
                data => $self->{data}->{$key},
                vers => $self->{vers}->{$key},
                time => $self->{time}->{$key},
            },
            {   # Theirs
                data => $value,
                vers => $version,
                time => $time,
            },
        );

        my $old = $self->{data}->{$key};

        $self->{data}->{$key} = $keep->{data};
        $self->{vers}->{$key} = $keep->{vers};
        $self->{time}->{$key} = $keep->{time};

        $self->{on_update}->($key, $keep->{data}, $old) if $self->{on_update};
    }

    unless (defined $self->{data}->{$key}) {
        # Postpone delete because it is necessary to keep the versioning 
        # of this modification until it is propagated to all workers
        $self->{_destroy}->{$key} = AnyEvent->timer( after => 60, cb => sub {
            delete $self->{_destroy}->{$key};
            delete $self->{data}->{$key};
            delete $self->{vers}->{$key};
            delete $self->{time}->{$key};
        });
    }
}

sub dump {
    my $self = shift;

    my @dump;

    foreach my $key (keys %{$self->{data}}) {
        push @dump, [
            $key,
            $self->{data}->{$key},
            $self->{vers}->{$key},
            $self->{time}->{$key},
        ];
    }

    return {
        uid   => $self->{uid},
        time  => Time::HiRes::time(),
        dump  => \@dump,
    };
}

sub _merge_dump {
    my ($self, $resp) = @_;

    return if ($resp->result->{uid} eq $self->{uid});

    foreach my $entry (@{$resp->result->{dump}}) {
        $self->_merge($entry);
    }
}

sub touch {
    my ($self, $key) = @_;

    return unless defined $self->{data}->{$key};

    croak "No max_age specified (gc is disabled)" unless $self->{max_age};

    my $age = time() - $self->{time}->{$key};

    return unless ( $age > $self->{max_age} * 0.3);
    return unless ( $age < $self->{max_age} * 1.3);

    # Set to current value but without increasing version
    $self->{vers}->{$key}--;

    $self->set( $key => $self->{data}->{$key} );
}

sub _gc {
    my $self = shift;

    my $min_time = time() - $self->{max_age} * 1.3;

    foreach my $key (keys %{$self->{data}}) {

        next unless ( $self->{time}->{$key} < $min_time );
        next unless ( defined $self->{data}->{$key} );

        $self->delete( $key );
    }
}


sub _save_state {
    my $self = shift;

    return unless ($self->{synced});

    my $id = $self->{id};
    my $tmp_file = "/tmp/beekeeper-cache-$id.dump";

    # Avoid stampede when several workers are exiting simultaneously
    return if (-e $tmp_file && (stat($tmp_file))[9] == time());

    # Lock file because several workers may try to write simultaneously to it
    sysopen(my $fh, $tmp_file, O_RDWR|O_CREAT) or return;
    flock($fh, LOCK_EX | LOCK_NB) or return;
    truncate($fh, 0) or return;

    print $fh encode_json( $self->dump );

    close($fh);
}

sub _load_state {
    my $self = shift;

    my $id = $self->{id};
    my $tmp_file = "/tmp/beekeeper-cache-$id.dump";
    return unless (-e $tmp_file);

    # Do not load stale dumps
    return if ($self->{max_age} && (stat($tmp_file))[9] < time() - $self->{max_age});

    local($/);
    open(my $fh, '<', $tmp_file) or die "Couldn't read $tmp_file: $!";
    my $data = <$fh>;
    close($fh);

    local $@;
    my $dump = eval { decode_json($data) };
    return if $@;

    foreach my $entry (@{$dump->{dump}}) {
        $self->_merge($entry);
    }
}

sub DESTROY {
    my $self = shift;
    $self->_save_state if $self->{persist};
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
