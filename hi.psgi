#!/usr/bin/env perl

use v5.14;

use Plack::Request;

sub main {
  my $env = shift;
  my $q = Plack::Request->new($env);
  use Data::Dumper;
  print STDERR "app: got " . Dumper($env);
  print STDERR "hello!\n";
  return [
    200,
    ['Content-type' => 'text/html'],
    [qq|
      <html>
        <body>
          hello @{[ $q->param('name') ]}<br/>
          <form method=POST>
            <input type=text name=name>
            <input type=submit>
          </form>
        </body>
      </html>
    |]
  ];
};

my $app = \&main;

use Plack::Builder;

builder {
  #enable 'Debug', panels => [qw( EBug )];
  enable 'Debug::EBug';
  $app;
};

