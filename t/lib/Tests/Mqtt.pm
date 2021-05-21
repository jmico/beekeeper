package Tests::Mqtt;

use strict;
use warnings;

use base 'Tests::Service::Base';
use Tests::Service::Config;
use Beekeeper::MQTT;

use Test::More;
use Time::HiRes 'sleep';
use Data::Dumper;

my $DEBUG = 1;

my $bus_config;

sub read_bus_config : Test(startup => 1) {
    my $self = shift;

    $bus_config = Beekeeper::Config->get_bus_config( bus_id => 'test' );

    ok( $bus_config->{host}, "Read bus config, connecting to " . $bus_config->{host});
}


sub test_01_topic : Test(3) {
    my $self = shift;

    my $bus1 = Beekeeper::MQTT->new( %$bus_config );
    my $bus2 = Beekeeper::MQTT->new( %$bus_config );

    $bus1->connect( blocking => 1 );
    $bus2->connect( blocking => 1 );

    my ($cv, $tmr);
    my @received;

    $bus1->subscribe(
        topic => 'foo/bar',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 1,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $bus2->subscribe(
        topic => 'foo/bar',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 2,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;


    $bus1->publish(
        topic   => 'foo/bar',
        payload => 'Hello 1',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 2, "received 2 messages from topic");
    is( $received[0]->{payload}, 'Hello 1', "got message");
    is( $received[1]->{payload}, 'Hello 1', "got message");

    # $DEBUG && diag Dumper \@received;

    $bus1->disconnect;
    $bus2->disconnect;
}

sub test_02_topic_wildcard : Test(7) {
    my $self = shift;

    my $bus1 = Beekeeper::MQTT->new( %$bus_config );
    my $bus2 = Beekeeper::MQTT->new( %$bus_config );

    $bus1->connect( blocking => 1 );
    $bus2->connect( blocking => 1 );

    my ($cv, $tmr);
    my @received;

    $bus1->subscribe(
        topic => 'foo/+',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus     => 1,
                headers => { %$properties },
                payload => $$payload,
            };
        },
    );

    $bus2->subscribe(
        topic => 'foo/#',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 2,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;


    $bus1->publish(
        topic   => 'foo/bar',
        payload => 'Hello 2',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 2, "received 2 messages from topic");
    is( $received[0]->{payload}, 'Hello 2', "got message");
    is( $received[1]->{payload}, 'Hello 2', "got message");

    # $DEBUG && diag Dumper \@received;

    @received = ();


    $bus1->publish(
        topic   => 'foobar',
        payload => 'Hello 3',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 0, "received no messages from topic");

    # $DEBUG && diag Dumper \@received;

    @received = ();


    $bus1->publish(
        topic   => 'foo/bar/baz',
        payload => 'Hello 4',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 1, "received 1 message from topic");
    is( $received[0]->{payload}, 'Hello 4', "got message");
    is( $received[0]->{bus}, 2, "got message");

    # $DEBUG && diag Dumper \@received;

    $bus1->disconnect;
    $bus2->disconnect;
}

sub test_03_shared_topic : Test(4) {
    my $self = shift;

    my $bus1 = Beekeeper::MQTT->new( %$bus_config );
    my $bus2 = Beekeeper::MQTT->new( %$bus_config );

    $bus1->connect( blocking => 1 );
    $bus2->connect( blocking => 1 );

    my ($cv, $tmr);
    my @received;

    $bus1->subscribe(
        topic => '$share/GROUPID/req/foo/bar',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 1,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $bus2->subscribe(
        topic => '$share/GROUPID/req/foo/bar',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 2,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;


    $bus1->publish(
        topic   => 'req/foo/bar',
        payload => 'Hello 5',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 1, "received 1 message from shared topic");
    is( $received[0]->{payload}, 'Hello 5', "got message");

    # $DEBUG && diag Dumper \@received;

    @received = ();


    $bus1->publish(
        topic   => 'req/foo/bar',
        payload => 'Hello 6',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 1, "received 1 message from shared topic");
    is( $received[0]->{payload}, 'Hello 6', "got message");

    # $DEBUG && diag Dumper \@received;

    $bus1->disconnect;
    $bus2->disconnect;
}

sub test_04_exclusive_topic : Test(11) {
    my $self = shift;

    my $bus1 = Beekeeper::MQTT->new( %$bus_config );
    my $bus2 = Beekeeper::MQTT->new( %$bus_config );
    my $bus3 = Beekeeper::MQTT->new( %$bus_config );

    $bus1->connect( blocking => 1 );
    $bus2->connect( blocking => 1 );
    $bus3->connect( blocking => 1 );

    my ($cv, $tmr);
    my (@received_1, @received_2, @received_3);

    $bus1->subscribe(
        topic => 'temp-12345',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received_1, {
                bus        => 1,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $bus2->subscribe(
        topic => '$share/GROUPID/foo/bar',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received_2, {
                bus        => 2,
                properties => { %$properties },
                payload    => $$payload,
            };
        },
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;


    $bus1->publish(
        topic          => 'foo/bar',
        response_topic => 'temp-12345',
        payload        => 'Hello 7',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received_2), 1, "received 1 message from exclusive topic");
    is( $received_2[0]->{payload}, 'Hello 7', "got message");

    my $reply_to = $received_2[0]->{properties}->{'response_topic'};
    ok( $reply_to, "got response_topic header");

    # $DEBUG && diag Dumper \@received_2;


    $bus2->publish(
        topic   => $reply_to,
        payload => 'Hello 8',
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received_1), 1, "received 1 message from exclusive topic");
    is( $received_1[0]->{payload}, 'Hello 8', "got message");

    # $DEBUG && diag Dumper \@received_1;

return;

    eval {
        # Try to subscribe to another connection temp-queue
        $bus3->subscribe(
            topic => $reply_to,
            on_publish => sub {
                my ($payload, $properties) = @_;
                push @received_3, {
                    bus        => 2,
                    properties => { %$properties },
                    payload    => $$payload,
                };
            },
        );

        $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;
    };

    if ($@) {
        # Either subscribe fail...
        ok(1, "can't subscribe to another connection temp topic");
        ok(1);
        ok(1);
    }
    else {
        # Or can't receive messages
        $bus2->publish(
            topic   => 'temp-12345',
            payload => 'Hello 9',
        );

        $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

        is( scalar(@received_1), 1, "did not received message from another exclusive topic with same topic");
        is( $received_1[-1]->{payload}, 'Hello 8', "did not received another message");

        is( scalar(@received_3), 0, "no message received from another connection exclusive topic");
    }

    eval {
        # Try to subscribe to another connection reply-to
        $bus3->connect( blocking => 1 ) unless $bus3->{is_connected};

        $bus3->subscribe(
            topic => $reply_to,
            on_publish => sub {
                my ($payload, $properties) = @_;
                push @received_3, {
                    bus        => 2,
                    properties => { %$properties },
                    payload    => $$payload,
                };
            },
        );

        $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;
    };

    if ($@) {
        # Either subscribe fail...
        ok(1, "can't subscribe to another connection reply-to");
        ok(1);
        ok(1);
    }
    else {
        # Or can't receive messages
        $bus2->publish(
            topic   => $reply_to,
            payload => 'Hello 10',
        );

        $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

        is( scalar(@received_1), 2, "sent another message to exclusive topic");
        is( $received_1[1]->{payload}, 'Hello 10', "sent message");

        is( scalar(@received_3), 0, "no message received from another connection reply-to");
    }


    $bus1->disconnect;
    $bus2->disconnect;
    $bus3->disconnect if $bus3->{is_connected};
}

sub test_05_shared_topic_queuing : Test(6) {
    my $self = shift;

    my $bus1 = Beekeeper::MQTT->new( %$bus_config );
    my $bus2 = Beekeeper::MQTT->new( %$bus_config );

    $bus1->connect( blocking => 1 );
    $bus2->connect( blocking => 1 );

    my ($cv, $tmr);
    my @received;

    $bus1->subscribe(
        topic       => '$share/GROUP_ID/req/foo/bar',
        maximum_qos => 1,
      # 'prefetch-count' => '1', #TODO
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 1,
                properties => $properties,
                payload    => $$payload,
            };
        },
    );

    $bus2->subscribe(
        topic       => '$share/GROUP_ID/req/foo/bar',
        maximum_qos => 1,
      # 'prefetch-count' => '1',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 2,
                properties => $properties,
                payload    => $$payload,
            };
        },
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;


    $bus1->publish(
        topic   => 'req/foo/bar',
        payload => 'Hello 11',
        qos     =>  1,
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 1, "received 1 message from shared topic");
    is( $received[0]->{payload}, 'Hello 11', "got message");

    # $DEBUG && diag Dumper \@received;


    $bus1->publish(
        topic   => 'req/foo/bar',
        payload => 'Hello 12',
        qos     =>  1,
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    is( scalar(@received), 2, "received 1 more message from shared topic");
    is( $received[1]->{payload}, 'Hello 12', "got message");

    # $DEBUG && diag Dumper \@received;


    # This one must be queued
    $bus1->publish(
        topic   => 'req/foo/bar',
        payload => 'Hello 13',
        qos     =>  1,
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    TODO: {
        local $TODO = "MQTT does not queue messages";
        is( scalar(@received), 2, "received no more messages until PUBACK");
    }

    for my $n (0..1) {

        my $packet_id = $received[$n]->{properties}->{'packet_id'};

        if ($received[$n]->{bus} == 1) {
            $bus1->puback( packet_id => $packet_id );
        }
        else {
            $bus2->puback( packet_id => $packet_id );
        }
    }

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    TODO: {
        local $TODO = "MQTT does not queue messages";
        is( scalar(@received), 3, "received another message");
    }

    # $DEBUG && diag Dumper \@received;

    for my $n (2..2) {

        my $packet_id = $received[$n]->{properties}->{'packet_id'};

        if ($received[$n]->{bus} == 1) {
            $bus1->puback( packet_id => $packet_id );
        }
        else {
            $bus2->puback( packet_id => $packet_id );
        }
    }

    $bus1->disconnect;
    $bus2->disconnect;
}

sub test_06_topic_timeout : Test(2) {
    my $self = shift;

    return "ToyBroker does not honor expiration yet" if $self->using_toybroker;

    my $bus1 = Beekeeper::MQTT->new( %$bus_config );

    $bus1->connect( blocking => 1 );

    my ($cv, $tmr);
    my @received;

    $bus1->publish(
        topic          => 'req/foo/bar',
        payload        => 'Message A',
        message_expiry => 1,
        retain         => 1,
    );

    $bus1->publish(
        topic          => 'req/foo/bar',
        payload        => 'Message B',
        message_expiry => 10,
        retain         => 1,
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1.5, cb => $cv); $cv->recv;


    $bus1->subscribe(
        topic => '$share/GROUP_ID/req/foo/bar',
        on_publish => sub {
            my ($payload, $properties) = @_;
            push @received, {
                bus        => 1,
                properties => $properties,
                payload    => $$payload,
            };
        },
    );

    $cv = AnyEvent->condvar; $tmr = AnyEvent->timer( after => 1, cb => $cv); $cv->recv;

    TODO: {
        local $TODO = "MQTT does not queue messages";
        # Message A should have expired
        is( scalar(@received), 1, "received only 1 message from topic");
        is( $received[0]->{payload}, 'Message B', "got non expired message");
    }
}

1;
