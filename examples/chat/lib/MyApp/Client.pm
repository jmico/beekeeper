package MyApp::Client;

use strict;
use warnings;

use MyApp::Service::Chat;
use MyApp::Service::Auth;

use Beekeeper::Client;

my $Help = "Available commands:
  /login username pass   Login
  /pm username message   Send private message
  /logout                End user session
  /kick user             End another user session
  /ping                  Measure latency
  /quit                  Exit (or use Ctrl-C)
";

sub new {
    my ($class, %args) = @_;
    my $self = {};

    $self->{fh} = $args{'fh'} || \*STDIN;

    # Connect to bus 'frontend-1', wich will forward requests to 'backend'
    $self->{client} = Beekeeper::Client->instance( bus_id => 'frontend-1', forward_to => 'backend' );

    $self->{chat} = MyApp::Service::Chat->new;
    $self->{auth} = MyApp::Service::Auth->new;

    bless $self, $class;
}

sub run {
    my $self = shift;

    print $Help;

    $self->{chat}->receive_messages( callback => sub {
        my %msg = @_;
        print "> ";
        print $msg{from} . ": " if $msg{from};
        print $msg{message} . "\n";
    });
 
    $self->{auth}->login( username => getpwuid($>), password => '123' );

    $self->{hdl} = AnyEvent::Handle->new( fh => $self->{fh} );

    $self->process_cmd("");

    $self->{quit_cv} = AnyEvent->condvar;
    $self->{quit_cv}->recv;
}

sub process_cmd {
    my ($self, $line) = @_;

    chomp $line;

    my $chat = $self->{chat};
    my $auth = $self->{auth};
    my $resp;

    CMD: {

        last unless (length $line);

        if ($line =~ m|^/login (\w+) (\w+)|i) {

            $resp = $auth->login( username => $1, password => $2 );
        }
        elsif ($line =~ m|^/kick (\w+)|i) {

            $resp = $auth->kick( username => $1 );
        }
        elsif ($line =~ m|^/logout\b|i) {

            $resp = $auth->logout;
        }
        elsif ($line =~ m|^/pm (\w+) (.+)|i) {

            $resp = $chat->send_private_message( username => $1, message => $2 );
        }
        elsif ($line =~ m|^/ping\b|i) {

            $resp = $chat->ping;
            print "> Ping: $resp ms\n";
            last;
        }
        elsif ($line =~ m|^/quit\b|i) {
            $self->{quit_cv}->send;
            last;
        }
        else {
            $resp = $chat->send_message( message => $line );
        }

        unless ($resp->success) {
            print "ERR: " . $resp->message . "\n";
        }
    }

    $self->{hdl}->push_read( line => sub {
        my ($hdl, $line) = @_;
        $self->process_cmd($line);
    });
}

1;

