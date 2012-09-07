#!/usr/bin/perl

use strict;
use Getopt::Long;
use DBI;
use Scalar::Util qw( looks_like_number );
use DateTime;

# Set the database/server/user/pass for your installation
my $database = 'exim';
my $server   = 'localhost';
my $user     = 'exim';
my $pass     = 'eximpassword';

# Global variables
my $dbh;
my %opts;
GetOptions( \%opts,
    'days:i',
    'test',
    'verbose',
);

sub dbh {
    unless ( $dbh && $dbh->ping() ) {
        $dbh = DBI->connect("dbi:mysql:$database:$server",$user,$pass);
    }
    return $dbh;
}

sub generateTableNames {
    my $days = shift();
    my $dt = DateTime->now();
    my $duration_object = DateTime::Duration->new( days => $days );
    $dt->subtract_duration( $duration_object );
    my $month = $dt->month();
    my $date = $dt->day();
    $month = sprintf( "%02i", $month );
    $date = sprintf( "%02i", $date );
    return ("mailIn_" . $month . "_" . $date,
            "mailOut_" . $month . "_" . $date);
}

my $days = $opts{days} || 30;
$days = looks_like_number( $days ) ? $days : 30;
my ( $mailIn, $mailOut ) = &generateTableNames( $days );
my $query;
$query = "DROP TABLE IF EXISTS $mailIn";
if ( $opts{'test'} ) {
    print $query, "\n";
} else {
    my $receivedDelete = &dbh->do( $query );
    print "Deleted $mailIn: $receivedDelete\n" if ( $opts{'verbose'} );
}
$query = "DROP TABLE IF EXISTS $mailOut";
if ( $opts{'test'} ) {
    print $query, "\n";
} else {
    my $sentDelete = &dbh->do( $query );
    print "Deleted $mailOut: $sentDelete\n" if ( $opts{'verbose'} );
}

# vim:tw=72 expandtab ts=4
