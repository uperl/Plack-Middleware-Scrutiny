#!/usr/bin/env perl

use v5.14;

my $app = sub {
  my $env = shift;
  use Data::Dumper;
  print STDERR "app: got " . Dumper($env);
  return [
    200,
    ['Content-type' => 'text/html'],
    ['<html><body>hello</body></html>']
  ];
};

use Plack::Builder;

builder {
  #enable 'Debug', panels => [qw( EBug )];
  enable 'Debug::EBug';
  $app;
};

