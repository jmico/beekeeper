#!/usr/bin/perl -wT

use strict;
use warnings;

BEGIN { unshift @INC, ($ENV{'PERL5LIB'} =~ m/([^:]+)/g); }


use Beekeeper::Client;
use Time::HiRes qw( time sleep );
use Getopt::Long;

my ($opt_count, $opt_number, $opt_rate, $opt_type, $opt_size, $opt_bench, $opt_help);
my $no_args = (@ARGV == 0) ? 1 : 0;

GetOptions(
    "type=s"    => \$opt_type,     # --type
    "count=i"   => \$opt_count,    # --count
    "n=i"       => \$opt_number,   # --n
    "rate=i"    => \$opt_rate,     # --rate
    "size=i"    => \$opt_size,     # --size
    "benchmark" => \$opt_bench,    # --benchmark
    "help"      => \$opt_help,     # --help    
) or exit;

my $Help = "
Usage: flood [OPTIONS]
Tool for benchmarking the STOMP framework.

  -t, --type str   type of requests to be made (N, J, B or A)
  -c, --count N    how many requests to be made
  -r, --rate  N    sustain a rate of N requests per second
  -s, --size  N    size in KB of requests, default is 0
  -n, --n     N    alias for --count
  -b, --benchmark  run a set of predefined benchmarks
  -h, --help       display this help and exit

To create a burst of 5000 notifications:

  flood --type N --count 5000

To create a constant load of 100 jobs per second:

  flood --type J --rate 100

Run a predefined set of benchmarks

  flood --benchmark

";

if ($opt_help || $no_args) {
    print $Help;
    exit;
}

my $client = Beekeeper::Client->instance;

if ($opt_bench) {
    # Predefined benchmarks
    print "\n";
    run_benchmarks();
}
else {
    # Flood / benchmark
    time_this(
        type  => $opt_type,
        count => $opt_count || $opt_number,
        rate  => $opt_rate,
        size  => $opt_size,
    );
}


sub time_this {

    my %args = (
        count => undef,
        rate  => undef,
        size  => undef,
        type  => undef,
        @_
    );

    my $size = $args{'size'} || 0;
    my $payload = { data => 'X' x ($size * 1024) };

    my $type = $args{'type'} || 'N';
    my @async_jobs;
    my $code;

    if ($type =~ m/^N(otification)?/i) {
        $type = 'notification';
        $code = sub {
            $client->send_notification(
                method => 'myapp.test.flood', 
                params => $payload,
            );
        };
    }
    elsif ($type =~ m/^J(ob)?/i) {
        $type = 'sync job';
        $code = sub {
            $client->do_job(
                method => 'myapp.test.echo', 
                params => $payload,
            );
        };
    }
    elsif ($type =~ m/^B(ackground)?(.job)?/i) {
        $type = 'background job';
        $code = sub {
            $client->do_background_job(
                method => 'myapp.test.echo', 
                params => $payload,
            );
        };
    }
    elsif ($type =~ m/^A(sync)?(.job)?/i) {
        $type = 'async job';
        $code = sub {
            push @async_jobs, $client->do_async_job(
                method => 'myapp.test.echo', 
                params => $payload,
            );
        };
    }
    else {
        die "type must be one of (N)otification, (J)ob, (B)ackground job or (A)sinc job\n";
    }

    my $rate = $args{'rate'} ? (1 / $args{'rate'}) : 0;
    my $max_count = $args{'count'} || ($rate ? -1 : 1000);

    my $quit;

    if ($rate) {
        print "Press ctrl-C to stop\n";
        $SIG{'INT'} = sub { $quit = 1; print "\b\b"; };
    }

    local $| = 1;
    printf( "%s %-16s of %3s Kb  ", $max_count, $type.'s', $size ) if (!$rate);

    my $count = 0;
    my $start = time();
    my $next = $start;
    my $sleept = 0;
    my $sleep;

    while (1) {

        &$code();

        $count++;

        last if ($quit || $count == $max_count);

        if ($rate) {
            $next += $rate;
            $sleep = $next - time();
            if ($sleep > 0) {
                $sleept += $sleep;
                sleep($sleep);
            }
        }
    }

    if ($type eq 'async job') {
        $client->wait_all_jobs;
        @async_jobs = ();
    }

    my $ellapsed = time() - $start - $sleept;
    my $took = sprintf("%.3f", $ellapsed);
    my $tps = sprintf("%.0f", $count / $ellapsed);
    my $avg = sprintf("%.2f", $ellapsed / $count * 1000);

    printf( "%s %-16s of %3s Kb  ", $count, $type.'s', $size ) if ($rate);
    printf( "in %6s sec  %6s /sec %6s ms each\n", $took, $tps, $avg );
}

sub run_benchmarks {

    my $count = $opt_count || $opt_number || 100;

    my @sizes = ( 0, 1, 5, 10 );

    # This clearly shows RabbitMQ bug of missing messages
    # for (1..10) { time_this( type => 'A', count => 40, size => 5 ); sleep 2 } return;

    # Notifications
    foreach (@sizes) {
        time_this( type => 'N', count => $count, size => $_ );
        sleep 1;
    }

    print "\n";

    # Jobs
    foreach (@sizes) {
        time_this( type => 'J', count => $count, size => $_ );
        sleep 1;
    }

    print "\n";

    # Async jobs
    foreach (@sizes) {
        time_this( type => 'A', count => $count, size => $_ );
        sleep 1;
    }

    print "\n";

    # Background jobs
    foreach (@sizes) {
        time_this( type => 'B', count => $count, size => $_ );
        sleep 1;
    }

    print "\n";
}


__END__

=head1 NAME

flood - ...

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

=head1 DESCRIPTION

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

Sample output:

# flood -b -c 1000

1000 notifications    of   0 Kb  in  0.057 sec   17673 /sec   0.06 ms each
1000 notifications    of   1 Kb  in  0.075 sec   13299 /sec   0.08 ms each
1000 notifications    of   5 Kb  in  0.084 sec   11850 /sec   0.08 ms each
1000 notifications    of  10 Kb  in  0.109 sec    9157 /sec   0.11 ms each

1000 sync jobs        of   0 Kb  in  1.533 sec     652 /sec   1.53 ms each
1000 sync jobs        of   1 Kb  in  1.542 sec     649 /sec   1.54 ms each
1000 sync jobs        of   5 Kb  in  1.692 sec     591 /sec   1.69 ms each
1000 sync jobs        of  10 Kb  in  1.920 sec     521 /sec   1.92 ms each

1000 async jobs       of   0 Kb  in  0.403 sec    2480 /sec   0.40 ms each
1000 async jobs       of   1 Kb  in  0.424 sec    2357 /sec   0.42 ms each
1000 async jobs       of   5 Kb  in  0.445 sec    2246 /sec   0.45 ms each
1000 async jobs       of  10 Kb  in  0.473 sec    2115 /sec   0.47 ms each

1000 background jobs  of   0 Kb  in  0.161 sec    6198 /sec   0.16 ms each
1000 background jobs  of   1 Kb  in  0.172 sec    5829 /sec   0.17 ms each
1000 background jobs  of   5 Kb  in  0.193 sec    5173 /sec   0.19 ms each
1000 background jobs  of  10 Kb  in  0.279 sec    3586 /sec   0.28 ms each

