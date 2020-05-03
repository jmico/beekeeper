#!/usr/bin/perl -wT

use strict;
use warnings;

$ENV{PATH} = '/bin'; # untaint

BEGIN {
    unless (eval { require Beekeeper }) {
        # Modules not installed yet
        unshift @INC, ($ENV{'PERL5LIB'} =~ m/([^:]+)/g);
    }
}

use MyApp::Calculator;


my $calc = MyApp::Calculator->new;

print "> ";

while (my $line = <STDIN>) {
    chomp $line;

    my $result = eval { $calc->eval_expr($line) };

    print $@ ? "ERR: $@" : "= $result\n";

    print "> ";
}

1;
