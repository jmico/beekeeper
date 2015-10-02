package MyApp::Service::Chat::Worker;

use strict;
use warnings;

use Beekeeper::Worker ':log';
use base 'Beekeeper::Worker';


sub authorize_request {
    my ($self, $req) = @_;

    $req->has_auth_tokens('USER');
}

sub on_startup {
    my $self = shift;

    $self->accept_jobs(
        'myapp.chat.message'  => 'message',
        'myapp.chat.pmessage' => 'private_message',
        'myapp.chat.ping'     => 'ping',
    );
}

sub message {
    my ($self, $params, $req) = @_;

    my $msg = $params->{'message'};
    my $from = $req->uuid;

    return unless (defined $msg && length $msg);

    #TODO: Filter message

    # Broadcast
    $self->send_notification(
        method => 'myapp.chat.message@frontend',
        params => { from => $from, message => $msg },
    );
}

sub private_message {
    my ($self, $params, $req) = @_;

    my $user = $params->{'username'};
    my $msg = $params->{'message'};
    my $from = $req->uuid;

    # Unicast
    $self->send_notification(
        method => "myapp.chat.pmessage\@frontend.user-$user",
        params => { from => 'me', message => $msg },
    );
}

sub ping {
    my ($self, $params) = @_;

    return 1;
}

1;
