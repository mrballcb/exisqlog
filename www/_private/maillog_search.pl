#!/usr/bin/perl

use strict;
use warnings;
use CGI qw/:cgi/;

# Path to the maillog script which connects to the database and
# performs queries.  Set to wherever you put the maillog script.
my $cmd = "/usr/local/bin/maillog";

my $q = CGI->new();
my %opts = map { $_ => $q->param($_) } $q->param();

my $return;
if ( ! $opts{'email_date'} ) {
  $opts{'email_date'} = `date '+\%b \%_d'`;
  chomp $opts{'email_date'};
  $return = "No date specified, using $opts{'email_date'}\n\n";
}
if ( ! $opts{'email_address'} ) {
  $return = "No email address supplied.";
} else {
  $opts{'email_date'} =~ s/[.,&_-]//g;
  $opts{'email_date'} =~ s/ +/ /g;
  $opts{'email_date'} =~ s/^ *//g;
  $opts{'email_date'} =~ s/ *$//g;
  $opts{'email_date'} = lc($opts{'email_date'});
  $opts{'email_date'} = ucfirst($opts{'email_date'});
  $return .= "Searching for email ";
  $return .= $opts{email_to} && $opts{email_from} ? "to/from " :
             $opts{email_to} ? "to " : 
             $opts{email_from} ? "from " : "to/from ";
  $return .= "$opts{'email_address'} on $opts{'email_date'}\n\n";

  # Strip anything after a semi-colon, all quotes, slashes and redirects
  $opts{'email_address'} =~ s/;.*//g;
  $opts{'email_address'} =~ s/['"\\<>]//g;

  if ( $opts{'email_to'} ) {
    $opts{'email_address'} = "--to '$opts{'email_address'}'";
  } elsif ( $opts{'email_from'} ) {
    $opts{'email_address'} = "--from '$opts{'email_address'}'";
  }

  $cmd .= " ";
  $cmd .= $opts{'email_long'} ? "" : "--short ";
  $cmd .= $opts{'skip_rbl'}   ? "--norbl " : '';
  $cmd .= $opts{'individual'} ? "--individual " : '';
  $cmd .= "--date='$opts{'email_date'}' $opts{'email_address'}";
  $return .= "$cmd\n";
  $return .= `$cmd`;
  $return  = CGI::escapeHTML($return);
  # Change mysql output to an opening div with a generic class
  $return =~ s/\*+ (\d+)\. row \*+/\n<div class='$1'>$1./g;
  # Close those div tags
  $return =~ s|(\n\n)(<div class=)|$1</div>$2|g;
  # Close the final div
  $return .= "</div>\n";
  my @temp = split(/\n/, $return);
  my $counter = 0;
  my $sent_counter = 0;
  my (@match_rbl,@match_sent,@match_local,@match_spam);
  foreach my $line ( @temp ) {
    if ( $line =~ /class='(\d+)'>/ ) {
      $counter = $1;
    }
    elsif ( $counter && $line =~ /mailSendStatus:\s+RBL Blocked/ ) {
      push(@match_rbl, $counter);
    }
    elsif ( $counter && $line =~ /mailSendStatus:\s+Completed/ ) {
      push(@match_local, $counter);
    }
    elsif ( $counter && $line =~ /mailSendStatus:.+SpamAssassin/ ) {
      push(@match_spam, $counter);
    }
    elsif ( $counter && $line =~ /mailDateSent:\s+\S+/ ) {
      $sent_counter = 1;
    }
    elsif ( $sent_counter == 1 && $line =~ /mailSendStatus:\s+\S+/ ) {
      $sent_counter = 0;
      push(@match_sent, $counter);
    }
  }
  foreach ( @match_rbl ) {
    $return =~ s/<div class='$_'>/<div class='rbl'>/;
  }
  foreach ( @match_local ) {
    $return =~ s/<div class='$_'>/<div class='local'>/;
  }
  foreach ( @match_spam ) {
    $return =~ s/<div class='$_'>/<div class='spam'>/;
  }
  foreach ( @match_sent ) {
    $return =~ s/<div class='$_'>/<div class='sent'>/;
  }
}

print "Content-type: text/plain\n\n";
print $return;
