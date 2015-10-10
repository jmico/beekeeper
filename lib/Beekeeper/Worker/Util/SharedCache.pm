package Beekeeper::Worker::Util::SharedCache;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Worker::Util::SharedCache - Locally mirrored shared cache

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

  use Beekeeper::Worker::Util 'shared_cache'
  
  my $c = $self->shared_cache(
      id      => "mycache",
      max_age => 300,
      persist => 1,
  );
  
  $c->set( $key => $value );
  $c->get( $key );
  $c->delete( $key );
  $c->touch( $key );

=head1 DESCRIPTION

This module implements a locally mirrored shared cache: each worker keeps a
copy of all cached data, and all copies are synced through message bus.

Access operations are essentially free, as data is held locally. But changes 
are expensive as they need to be propagated to every worker, and memory usage
is high due to data cloning.

Keep in mind that retrieved data may be stale due to latency in changes 
propagation through the bus (which involves two network operations).

Even if you are using this cache for small data sets that do not change very
often, please consider if a distributed cache like Memcache or Redis (or even
a plain DB) are a better alternative.

=cut

use Beekeeper::Worker ':log';
use AnyEvent;
use JSON::XS;
use Fcntl qw(:DEFAULT :flock);
use Scalar::Util 'weaken';
use Carp;


sub new {
    my ($class, %args) = @_;

    my $worker = $args{'worker'};
    my $id     = $args{'id'};
    my $uid    = "$$-" . int(rand(90000000)+10000000);

    my $self = {
        id        => $id,
        uid       => $uid,
        resolver  => $args{'resolver'},
        on_update => $args{'on_update'},
        persist   => $args{'persist'},
        max_age   => $args{'max_age'},
        refresh   => $args{'refresh'},
        cluster   => [],
        synced    => 0,
        data      => {},
        vers      => {},
        time      => {},
    };

    bless $self, $class;

    $self->_load_state if $self->{persist};

    $self->_connect_to_all_brokers($worker);

    if ($self->{max_age}) {
        my $Self = $self;
        $self->{gc_timer} = AnyEvent->timer(
            after    => $self->{max_age} * rand() + 60,
            interval => $self->{max_age},
            cb       => sub { $Self->_gc },
        );
    }

    if ($self->{refresh}) {
        my $Self = $self;
        $self->{refresh_timer} = AnyEvent->timer(
            after    => $self->{refresh} * rand() + 60,
            interval => $self->{refresh},
            cb       => sub { $Self->_send_sync_request },
        );
    }

    return $self;
}

sub _cluster_config {
    my ($self, $worker) = @_;

    my $bus_config = $worker->{_WORKER}->{bus_config};
    my $bus_id = $worker->{_BUS}->bus_id;
    my $cluster_id = $bus_config->{$bus_id}->{'cluster'};

    unless ($cluster_id) {
        # No clustering defined, just a single backend broker
        return [ $bus_config->{$bus_id} ];
    }

    my @cluster_config;

    foreach my $config (values %$bus_config) {
        next unless $config->{'cluster'} && $config->{'cluster'} eq $cluster_id;
        push @cluster_config, $config;
    }

    return \@cluster_config;
}

sub _connect_to_all_brokers {
    my ($self, $worker) = @_;
    weaken($self);

    my $cluster_config = $self->_cluster_config($worker);

    foreach my $config (@$cluster_config) {

        my $bus_id = $config->{'bus-id'};

        if ($bus_id eq $worker->{_BUS}->bus_id) {
            # Already connected to our own bus
            $self->_setup_sync_listeners($worker->{_BUS});
            $self->_send_sync_request($worker->{_BUS}) unless $self->{synced};
            next;
        }

        my $bus; $bus = Beekeeper::Bus::STOMP->new( 
            %$config,
            bus_id     => $bus_id,
            timeout    => 300,
            on_connect => sub {
                # Setup
                log_debug "Connected to $bus_id";
                $self->_setup_sync_listeners($bus);
                $self->_send_sync_request($bus) unless $self->{synced};
            },
            on_error => sub {
                # Reconnect
                my $errmsg = $_[0] || ""; $errmsg =~ s/\s+/ /sg;
                log_error "Connection to $bus_id failed: $errmsg";
                delete $self->{ready}->{$bus_id};
                my $delay = $self->{connect_err}->{$bus_id}++;
                $self->{reconnect_tmr}->{$bus_id} = AnyEvent->timer(
                    after => ($delay < 10 ? $delay * 3 : 30),
                    cb    => sub { $bus->connect },
                );
            },
        );

        push @{$self->{cluster}}, $bus;

        $bus->connect;
    }
}

sub _setup_sync_listeners {
    my ($self, $bus) = @_;
    weaken($self);

    my $cache_id = $self->{id};
    my $uid      = $self->{uid};
    my $bus_id   = $bus->{bus_id};

    $bus->subscribe(
        destination    => "/topic/msg.$bus_id._sync.$cache_id.set",
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;

            my $entry = decode_json($$body_ref);

            $self->_merge($entry);
        }
    );

    $bus->subscribe(
        destination    => "/temp-queue/reply-$uid",
        on_receive_msg => sub {
            my ($body_ref, $msg_headers) = @_;

            my $dump = decode_json($$body_ref);

            $self->_merge_dump($dump);

            $self->_sync_completed(1);
        }
    );

    if ($self->{synced}) {

        $self->_accept_sync_requests($bus);
    }
}

sub _send_sync_request {
    my ($self, $bus) = @_;
    weaken($self);

    return if $self->{_sync_wait};

    my $cache_id = $self->{id};
    my $uid      = $self->{uid};
    my $bus_id   = $bus->{bus_id};

    $bus->send(
        destination => "/queue/req.$bus_id._sync.$cache_id.dump",
       'reply-to'   => "/temp-queue/reply-$uid",
        body        => "",
    );

    # When a fresh pool is started nobody will answer, and determining which
    # worker have the best data set is a complex task when persistence and
    # clustering is involved. By now let the older workers act as masters
    my $timeout = 20 + rand();

    if ($self->{persist}) {
        # Give precedence to workers with bigger data sets
        my $size = keys %{$self->{data}};
        $timeout += 20 / (1 + log($size + 1));
    }

    $self->{_sync_wait} = AnyEvent->timer(
        after => $timeout,
        cb    => sub { $self->_sync_completed(0) },
    );
}

sub _sync_completed {
    my ($self, $success) = @_;

    delete $self->{_sync_wait};

    $self->{synced} = 1;

    log_debug( $success ? "Sync completed" : "Acting as master" );

    foreach my $bus ( @{$self->{cluster}} ) {

        $self->_accept_sync_requests( $bus );
    }
}

sub _accept_sync_requests {
    my ($self, $bus) = @_;
    weaken($self);
    weaken($bus);

    my $cache_id = $self->{id};
    my $uid      = $self->{uid};
    my $bus_id   = $bus->{bus_id};

    return if $self->{ready}->{$bus_id};
    $self->{ready}->{$bus_id} = 1;

    log_debug "Accepting $cache_id sync requests from $bus_id";

    $bus->subscribe(
        destination     => "/queue/req.$bus_id._sync.$cache_id.dump",
        ack             => 'client', # manual ack
       'prefetch-count' => '1',
        on_receive_msg  => sub {
            my ($body_ref, $msg_headers) = @_;

            my $dump = encode_json( $self->dump );

            $bus->send(
                destination => $msg_headers->{'reply-to'},
                body        => \$dump,
            );

            $bus->ack(
                subscription => $msg_headers->{'subscription'}, 
                id           => $msg_headers->{'message-id'},
            );
        }
    );
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

    my @cluster = grep { $_->{is_connected} } @{$self->{cluster}};
    croak "Not connected to broker" unless @cluster;

    my $bus = $cluster[rand @cluster];
    my $bus_id = $bus->{bus_id};
    my $cache_id = $self->{id};

    $bus->send(
        destination => "/topic/msg.$bus_id._sync.$cache_id.set",
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

    my ($key, $value, $version, $time, $uid) = @$entry;

    # Discard updates sent by myself
    return if (defined $uid && $uid eq $self->{uid});

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
    my ($self, $dump) = @_;

    # Discard dumps sent by myself
    return if ($dump->{uid} eq $self->{uid});

    foreach my $entry (@{$dump->{dump}}) {
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

    my $min_time = $self->{max_age} ? time() - $self->{max_age} : undef;

    foreach my $entry (@{$dump->{dump}}) {
        next if ($min_time && $entry->[3] < $min_time);
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
