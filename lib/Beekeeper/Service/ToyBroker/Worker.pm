package Beekeeper::Service::ToyBroker::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

use Beekeeper::Config;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Scalar::Util 'weaken';

use constant STOMP_PORT => 61613;

our $VERSION = '0.01';

=head1 NAME

Beekeeper::Service::ToyBroker::Worker - Basic STOMP 1.2 broker

=head1 VERSION

Version 0.01

=head1 DESCRIPTION

ToyBroker implements the STOMP subset needed to run a Beekeeper worker pool.

Being single threaded it does not scale at all, but it is handy for development
or running tests.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = $class->SUPER::new(%args);

    $self->start_broker;

    eval {
        $self->SUPER::__init_client;

        $self->{_LOGGER}->{_BUS} = $self->{_BUS};

        $self->SUPER::__init_worker;
    };

    if ($@) {
        log_error "Worker died while initialization: $@";
        log_error "$class could not be started";
        CORE::exit( 99 );
    }

    return $self;
}

sub __init_client { }
sub __init_worker { }
sub on_startup    { }

sub on_shutdown {
    my $self = shift;

    # Wait for clients gracefully disconnection
    for (1..50) {
        last unless (keys %{$self->{connections}} <= 1); # our one
        my $wait = AnyEvent->condvar;
        my $tmr = AnyEvent->timer( after => 0.1, cb => $wait );
        $wait->recv;
    }
}

sub authorize_request {
    my ($self, $req) = @_;

    return REQUEST_AUTHORIZED;
}

sub start_broker {
    my $self = shift;
    weaken($self);

    my $config = Beekeeper::Config->read_config_file( 'toybroker.config.json' ) || {};

    my $listen_addr = $config->{'listen_addr'} || '127.0.0.1';  # Must be an IPv4 or IPv6 address
    my $listen_port = $config->{'listen_port'} ||  61613;

    ($listen_addr) = ($listen_addr =~ m/^([\w\.:]+)$/);  # untaint
    ($listen_port) = ($listen_port =~ m/^(\d+)$/);

    $self->{connections} = {};
    $self->{queues}      = {};
    $self->{topics}      = {};

    $self->{broker} = tcp_server ($listen_addr, $listen_port, sub {
        my ($fh, $host, $port) = @_;

        my $login_tmr = AnyEvent->timer( after => 5, cb => sub {
            $fh->push_shutdown unless $fh->{authorized};
        });

        my $frame_cmd;
        my %frame_hdr;
        my $body_lenght;

        my $hdl; $hdl = AnyEvent::Handle->new(
            fh => $fh,
            on_read => sub {
                my $fh = $_[0];
                my $raw_headers;
                my ($line, $key, $value);

                PARSE_FRAME: {

                    unless ($frame_cmd) {

                        # Parse header
                        $fh->{rbuf} =~ s/ ^.*?           # ignore heading garbage (just in case)
                                          \n*            # ignore client heartbeats
                                         ([A-Z]+)\n      # frame command
                                         (.*?)           # one or more lines of headers
                                          \n\n           # end of headers
                                        //sx or return;

                        $frame_cmd   = $1;
                        $raw_headers = $2;

                        foreach $line (split(/\n/, $raw_headers)) {
                            ($key, $value) = split(/:/, $line, 2);
                            # On duplicated headers only the first one is valid
                            $frame_hdr{$key} = $value unless ($key && exists $frame_hdr{$key});
                        }

                        # content-length may be explicitly specified or not
                        $body_lenght = $frame_hdr{'content-length'};
                        $body_lenght = -1 unless (defined $body_lenght);
                    }

                    if ($body_lenght >= 0) {
                        # If body lenght is known wait until readed enough data
                        return if (length $fh->{rbuf} < $body_lenght + 1);
                    }
                    else {
                        # If body lenght is unknown wait until readed frame separator
                        $body_lenght = index($fh->{rbuf}, "\x00");
                        return if ($body_lenght == -1);
                    }

                    my $body = substr($fh->{rbuf}, 0, $body_lenght + 1, '');
                    chop $body; # remove frame separator

                    if ($frame_cmd eq 'SEND') {
                        $self->send( $fh, \%frame_hdr, \$body );
                    }
                    elsif ($frame_cmd eq 'ACK') {
                        $self->ack( $fh, \%frame_hdr );
                    }
                    elsif ($frame_cmd eq 'NACK') {
                        $self->nack( $fh, \%frame_hdr );
                    }
                    elsif ($frame_cmd eq 'SUBSCRIBE') {
                        $self->subscribe( $fh, \%frame_hdr );
                    }
                    elsif ($frame_cmd eq 'UNSUBSCRIBE') {
                        $self->unsubscribe( $fh, \%frame_hdr );
                    }
                    elsif ($frame_cmd eq 'CONNECT') {
                        $self->connect( $fh, \%frame_hdr, "$host:$port" );
                    }
                    elsif ($frame_cmd eq 'DISCONNECT') {
                        $self->disconnect( $fh, \%frame_hdr );
                    }
                    elsif ($frame_cmd eq 'BEGIN') {
                        $self->error( $fh, "BEGIN is not implemented");
                    }
                    elsif ($frame_cmd eq 'COMMIT') {
                        $self->error( $fh, "COMMIT is not implemented");
                    }
                    elsif ($frame_cmd eq 'ABORT') {
                        $self->error( $fh, "ABORT is not implemented");
                    }
                    else {
                        $self->error($fh, "Invalid command $frame_cmd");
                    }

                    # Prepare for next frame
                    undef $frame_cmd;
                    undef $body_lenght;
                    %frame_hdr = ();

                    redo PARSE_FRAME if (defined $fh->{rbuf} && length $fh->{rbuf} > 1);
                }
            },
            on_error => sub {
                # my ($fh, $fatal, $message) = @_;
                $self->_clear_subscriptions($hdl);
                delete $self->{connections}->{"$hdl"};
                undef $hdl;
            }
        );
    });
}

sub connect {
    my ($self, $fh, $hdr, $remote_addr) = @_;

    my $user = $hdr->{'login'};
    my $pass = $hdr->{'passcode'};

    # $user/$pass from $remote_addr
    my $authorized = 1;

    unless ($authorized) {
        $self->error($fh, 'Not authorized');
        return;
    }

    $fh->push_write(
        "CONNECTED\n"                 .
        "server:ToyBroker $VERSION\n" .
        "version:1.2\n\n"             .
        "\x00"
    );

    $fh->{user}  = $user;
    $fh->{vhost} = $hdr->{'host'} || '';

    $fh->{authorized} = 1;
    $fh->{topic_subs} = {};
    $fh->{queue_subs} = {};

    $self->{connections}->{"$fh"} = $fh;
}

sub disconnect {
    my ($self, $fh, $hdr) = @_;

    $self->receipt($fh, $hdr);

    $self->_clear_subscriptions($fh);
    delete $self->{connections}->{"$fh"};

    $fh->push_shutdown;
}

sub error {
    my ($self, $fh, $msg) = @_;

    $fh->push_write(
        "ERROR\n"           .
        "message: $msg\n\n" .
        "$msg\n"            .
        "\x00"
    );

    $self->_clear_subscriptions($fh);

    $fh->push_shutdown;
}

sub _clear_subscriptions {
    my ($self, $fh) = @_;

    my $topic_subs = $fh->{topic_subs};
    my $queue_subs = $fh->{queue_subs};

    foreach my $sub_id (keys %$topic_subs) {
        my $dest = $topic_subs->{$sub_id};
        $self->_unsubscribe_from_topic($fh, $dest);
    }

    foreach my $sub_id (keys %$queue_subs) {
        my $dest = $queue_subs->{$sub_id};
        $self->_unsubscribe_from_queue($fh, $dest);
    }
}

sub receipt {
    my ($self, $fh, $hdr) = @_;

    return unless $hdr->{'receipt'};

    $fh->push_write(
        "RECEIPT\n"                      .
        "receipt-id:$hdr->{receipt}\n\n" .
        "\x00"
    );
}

sub subscribe {
    my ($self, $fh, $hdr) = @_;

    my $dest   = $hdr->{destination};
    my $sub_id = $hdr->{id};

    unless ($dest && $dest =~ m|^/[-\w]+/[-*#\w]+(\.[-*#\w]+)*$|) {
        $self->error($fh, "Invalid destination");
        return;
    }

    if ($dest =~ s|^/(temp-)?topic/||) {

        my $temp = $1;

        $dest = $fh->{vhost} .'/'. $dest;

        if ($temp && exists $self->{topics}->{$dest}) {
            $self->error($fh, "Forbidden destination");
            return;
        }

        if (exists $fh->{topic_subs}->{$sub_id}) {
            $self->error($fh, "Subscription id already in use");
            return;
        }

        $fh->{topic_subs}->{$sub_id} = $dest;

        my $dest_re = $dest;
        $dest_re =~ s/\./\\./g;
        $dest_re =~ s/\*/[^.]+/g;
        $dest_re =~ s/\#/.+/g;

        my $topic = $self->{topics}->{$dest} ||= {
            subscribers => [],
            dest_regex  => qr/^${dest_re}$/,
        };

        push @{$topic->{subscribers}}, {
            fh_id  => "$fh",
            sub_id => $sub_id,
            msg_id => 1,
        };
    }
    elsif ($dest =~ s|^/(temp-)?queue/||) {

        my $temp = $1;

        $dest = $fh->{vhost} .'/'. $dest;

        if ($temp && exists $self->{queues}->{$dest}) {
            $self->error($fh, "Forbidden destination");
            return;
        }

        if (exists $fh->{queue_subs}->{$sub_id}) {
            $self->error($fh, "Subscription with same id already exists");
            return;
        }

        $fh->{queue_subs}->{$sub_id} = $dest;

        my $ack_mode = $hdr->{ack} || 'auto';
        my $prefetch = $hdr->{'prefetch-count'};
        my $ack = ($ack_mode eq 'client') ? 1 : 0;

        my $queue = $self->{queues}->{$dest} ||= {
            subscribers => [],
            messages    => [],
        };

        push @{$queue->{subscribers}}, {
            fh_id  => "$fh",
            sub_id => $sub_id,
            ack    => $ack,
            msg_id => 1,
        };

        $self->_service_queue($dest);
    }
    else {

        $self->error($fh, "Invalid destination");
        return;
    }

    $self->receipt($fh, $hdr);
}

sub unsubscribe {
    my ($self, $fh, $hdr) = @_;

    my $sub_id = $hdr->{id};
    my $dest;

    if ($dest = delete $fh->{queue_subs}->{$sub_id}) {

        $self->_unsubscribe_from_queue($fh, $dest);
    }
    elsif ($dest = delete $fh->{topic_subs}->{$sub_id}) {

        $self->_unsubscribe_from_topic($fh, $dest);
    }
    else {
        $self->error($fh, "Invalid subscription id");
        return;
    }

    $self->receipt($fh, $hdr);
}

sub _unsubscribe_from_queue {
    my ($self, $fh, $dest) = @_;

    my $queue = $self->{queues}->{$dest} || return;

    @{$queue->{subscribers}} = grep { $_->{fh_id} ne "$fh" } @{$queue->{subscribers}};

    delete $self->{queues}->{$dest} unless (@{$queue->{subscribers}} || @{$queue->{messages}});
}

sub _unsubscribe_from_topic {
    my ($self, $fh, $dest) = @_;

    my $topic = $self->{topics}->{$dest} || return;

    @{$topic->{subscribers}} = grep { $_->{fh_id} ne "$fh" } @{$topic->{subscribers}};

    delete $self->{topics}->{$dest} unless @{$topic->{subscribers}};
}

sub send {
    my ($self, $fh, $hdr, $msg) = @_;

    my $dest = delete $hdr->{destination};

    if ($dest =~ s|^/(temp-)?queue/||) {

        $dest = $fh->{vhost} .'/'. $dest;
        $self->_send_to_queue($dest, $hdr, $msg);
    }
    elsif ($dest =~ s|^/(temp-)?topic/||) {

        $dest = $fh->{vhost} .'/'. $dest;
        $self->_send_to_topic($dest, $hdr, $msg);
    }
    else {
        $self->error($fh, "Invalid destination");
        return;
    }

    $self->receipt($fh, $hdr);
}

sub _send_to_topic {
    my ($self, $dest, $hdr, $msg) = @_;

    $self->{_WORKER}->{notif_count}++; # inbound

    $hdr->{'content-length'} = length($$msg);

    foreach my $topic (keys %{$self->{topics}}) {

        next unless ($dest =~ $self->{topics}->{$topic}->{dest_regex});

        my $subscribers = $self->{topics}->{$topic}->{subscribers};

        foreach my $subscr (@$subscribers) {

            my $fh = $self->{connections}->{$subscr->{fh_id}};
            next unless $fh;

            $subscr->{msg_id}++;

            $hdr->{'subscription'} = $subscr->{sub_id};
            $hdr->{'message-id'}   = $subscr->{msg_id};

            my $headers = join '', map { "$_:$hdr->{$_}\n" } keys %$hdr;

            $fh->push_write(
                "MESSAGE\n" .
                $headers    .
                "\n"        .
                $$msg       .
                "\x00"
            );

            # $self->{_WORKER}->{notif_count}++; # outbound
        }
    }
}

sub _send_to_queue {
    my ($self, $dest, $hdr, $msg) = @_;

    $self->{_WORKER}->{jobs_count}++; # inbound

    my $queue = $self->{queues}->{$dest} ||= {
        subscribers => [],
        messages    => [],
    };

    push @{$queue->{messages}}, { %$hdr, _msg => $$msg }; # make a copy

    $self->_service_queue($dest);
}

sub _service_queue {
    my ($self, $dest) = @_;

    my $queue       = $self->{queues}->{$dest};
    my $subscribers = $queue->{subscribers};
    my $messages    = $queue->{messages};

    return unless @$messages && @$subscribers;

    # Round robin
    my $next = pop @$subscribers;
    unshift @$subscribers, $next;

    foreach my $subscr (@$subscribers) {

        my $fh = $self->{connections}->{$subscr->{fh_id}};
        next unless $fh;

        my $ack_id = $subscr->{sub_id} .':'. $subscr->{msg_id};
        next if ($subscr->{ack} && $fh->{pending_ack}->{$ack_id});

        my $hdr = shift @$messages;
        my $msg = delete $hdr->{_msg};

        $subscr->{msg_id}++;

        $hdr->{'content-length'} = length($msg);
        $hdr->{'subscription'}   = $subscr->{sub_id};
        $hdr->{'message-id'}     = $subscr->{msg_id};

        if ($subscr->{ack}) {
            $ack_id = $subscr->{sub_id} .':'. $subscr->{msg_id};
            $fh->{pending_ack}->{$ack_id} = $dest;
            $hdr->{'ack'} = $ack_id;
        }

        my $headers = join '', map { "$_:$hdr->{$_}\n" } keys %$hdr;

        $fh->push_write(
            "MESSAGE\n" .
            $headers    .
            "\n"        .
            $msg       .
            "\x00"
        );

        # $self->{_WORKER}->{jobs_count}++; # outbound

        last unless @$messages;
    }
}

sub ack {
    my ($self, $fh, $hdr) = @_;

    my $id = $hdr->{'id'} ||                                     # STOMP 1.2                 
             $hdr->{'subscription'} .':'. $hdr->{'message-id'};  # STOMP 1.1

    my $dest = delete $fh->{pending_ack}->{$id};

    unless ($dest) {
        $self->error($fh, "Unmatched ACK");
        return;
    }

    $self->_service_queue($dest);
}

1;
