package MyApp::Service::Chat::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';

sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.chat.message'  => 'message',
        'myapp.chat.pmessage' => 'private_message',
        'myapp.chat.ping'     => 'ping',
    );
}

sub message {
    my ($self, $params) = @_;

    my $msg = $params->{'message'};
    my $from = 'me';

    return unless (defined $msg && length $msg);

    #TODO: Filter message

    $self->send_notification(
        method => 'myapp.chat.message@frontend',
        params => { from => $from, message => $msg },
    );
}

sub private_message {
    my ($self, $params) = @_;

    my $user = $params->{'username'};
    my $msg = $params->{'message'};

    $self->send_notification(
        method => "myapp.chat.message\@frontend.user-$user",
        params => { from => 'me', message => $msg },
    );
}

sub ping {
    my ($self, $params) = @_;

    return 1;
}

1;
