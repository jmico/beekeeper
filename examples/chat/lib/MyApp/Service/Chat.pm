package MyApp::Service::Chat;

use strict;
use warnings;

use Beekeeper::Client;
use Time::HiRes;


sub new {
    my $class = shift;
    bless {}, $class;
}

sub do_job {
    my $self = shift;

    Beekeeper::Client->instance->do_job(@_);
}


# This is the API of service MyApp::Service::Chat

sub send_message {
    my ($self, %args) = @_;

    $self->do_job(
        method => 'myapp.chat.message',
        params => {
            message => $args{'message'},
        },
    );
}

sub send_private_message {
    my ($self, %args) = @_;

    $self->do_job(
        method => 'myapp.chat.pmessage',
        params => {
            username => $args{'username'},
            message  => $args{'message'},
        },
    );
}

sub ping {
    my ($self) = @_;

    my $now = Time::HiRes::time;

    $self->do_job(
        method => 'myapp.chat.ping',
    );

    my $took = Time::HiRes::time - $now;

    return sprintf("%.1f", $took * 1000);
}

sub receive_messages {
    my ($self, %args) = @_;

    my $callback = $args{'callback'};

    Beekeeper::Client->instance->accept_notifications(
        'myapp.chat.*' => sub { 
            my $params = shift;
            $callback->(
                message => $params->{'message'},
                from    => $params->{'from'},
            );
        },
    );
}

1;
