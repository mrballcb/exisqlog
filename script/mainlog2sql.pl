#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Sys::Hostname;
use DBI;
use Data::Dumper;

# Set the database/server/user/pass for your installation
my $database = 'exim';
my $server   = 'localhost';
my $user     = 'exim';
my $pass     = 'eximpassword';
# The above would translate to the mysql commands:
# CREATE DATABASE 'exim';
# GRANT ALL ON exim.* TO 'exim'@'localhost' IDENTIFIED BY 'eximpassword'
# FLUSH PRIVILEGES;

# Global variables
my $dbh;
my $hostname=hostname();
# You may need to customize or comment out this next line
# which lops off the domain portion of the hostname.
$hostname =~ s/^(\w+)\..*/$1/;
my $qhostname = &dbh->quote( $hostname );
my ($step,$rfc_step,$spam,$rfc_2822,$spf) = (0,0,{},{});
my $global = { mailIn => '', mailOut => '' };

my %opts = ( 'chunk' => 10000,
);

GetOptions( \%opts,
    'chunk|chunksize:i',
    'debug',
    'rejects',
    'test',
    'verbose',
);

my $lastMonthDate='';
my $loopcounter = $opts{chunk};
while (<STDIN>) {
    &processLine($_);
    $loopcounter--;
    if ( $loopcounter eq 0 ) {
        sleep 1;
        $loopcounter = $opts{chunk};
    }
}

sub dodbh {
    my $query = shift();
    if ( $opts{'test'} ) {
        print $query, "\n";
    } else {
       &dbh->do( $query );
    }
}

sub dbh {
    unless ( $dbh && $dbh->ping() ) {
        $dbh = DBI->connect("dbi:mysql:$database:$server",$user,$pass) or die "Failed to connect to $server";
    }
    return $dbh;
}

sub convert_date {
    my $date = shift();
    my $newdate = $date;
    if ( $date =~ m/(\d\d\d\d)-(\d\d)-(\d\d)\s(\d\d:\d\d:\d\d)/ ) {
        my $year  = $1;
        my $month = $2;
        my $date  = $3;
        my $time  = $4;
        my $currentMonthDate = "${month}_${date}";
        $newdate = $year . "-" . $month . "-" . $date . " " . $time;
        # This is a global variable to track month rollover
        if ( $currentMonthDate !~ /^$lastMonthDate$/ ) {
            &createNewTable( $currentMonthDate );
        }
        $lastMonthDate = $currentMonthDate;
    }
    return $newdate;
}

sub tableExists {
    my $date = shift();
    return 1 if ( $opts{'test'} );
    my $present = &dbh->do( "SHOW TABLES LIKE '%${date}'" );
    print $present, "\n" if ( $opts{'debug'} );
    if ( $present =~ /0E0/ ) {
        return 0;
    }
    return $present;
}

sub createNewTable {
    my $date = shift();
    return if &tableExists( $date );
    if ( $opts{'debug'} ) {
        print "DEBUG: Creating tables for $date\n";
    }
    &dbh->do( "DROP TABLE IF EXISTS `mailIn_$date`" );
    &dbh->do( "CREATE TABLE `mailIn_$date` (
  `mailId` int UNSIGNED AUTO_INCREMENT,
  `mailqId` char(48) NOT NULL,
  `mailDateReceived` datetime NOT NULL,
  `mailHost` varchar(30) default NULL,
  `mailFrom` varchar(255) default NULL,
  `mailSize` int UNSIGNED default 0,
  `mailSPFStatus` varchar(255),
  `mailSpamScore` decimal(4,1) default 0.0,
  `mailSpamRules` varchar(1023),
  `mailSpamReport` varchar(511),
  `mailReceiveStatus` varchar(200),
  `mailInRelay` varchar(100),
  PRIMARY KEY (`mailId`),
  KEY `mailqIdx` (`mailqId`),
  KEY `fromIdx` (`mailFrom`),
  KEY `dateIdx` (`mailDateReceived`)
  ) ENGINE=InnoDB CHARSET=latin1;" );
    &dbh->do( "DROP TABLE IF EXISTS `mailOut_$date`;" );
    &dbh->do( "CREATE TABLE `mailOut_$date` (
  `mailId` int UNSIGNED AUTO_INCREMENT,
  `mailqId` char(48) NOT NULL,
  `mailTo` varchar(255) NOT NULL,
  `mailForwardedTo` varchar(255) default NULL,
  `mailAlias` varchar(255) default NULL,
  `mailDateSent` datetime NOT NULL,
  `mailRBLStatus` varchar(255),
  `mailSendStatus` varchar(255),
  `mailOutRelay` varchar(100),
  PRIMARY KEY (`mailId`),
  KEY `mailqIdx` (`mailqId`),
  KEY `toIdx` (`mailTo`)
  ) ENGINE=InnoDB CHARSET=latin1;" );
}

sub generateTableNames {
    my $line = shift();
    if ( $line =~ /^\d\d\d\d-(\d\d)-(\d\d)\s/ ) {
        my $month = $1;
        my $date = $2;
        $global = { mailIn => "mailIn_" . $month . "_" . $date,
                    mailOut => "mailOut_" . $month . "_" . $date
                  };
        return ($global->{'mailIn'}, $global->{'mailOut'} );
    } elsif ( $global->{'mailIn'} && $global->{'mailOut'} ) {
        return ($global->{'mailIn'}, $global->{'mailOut'} );
    } else {
        return (undef, undef);
    }
}

sub processLine {
    my $line = shift();
    chomp( $line );

    # Jump out of here if find things we don't want to waste cycles processing
    my @skip = ( 'retry time not reached', 'no host name found for IP' );
    foreach ( @skip ) {
        return if ( $line =~ /$_/ );
    }

    my ( $mailIn,$mailOut ) = &generateTableNames( $line );
    my ( $date,$qdate,$mailqId );
    # First extract the date:
    if ( $line =~ s/^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d)\s// ) {
        $date = $1;
        $date = &convert_date($date);
    } else {
        return unless ( $step || $rfc_step );
    }

    my $bad_mime_regex='(rejected during MIME ACL checks: .*)';
    my $defer_regex='defer \(-?\d+\): (SMTP error from remote mail server after (?:initial commection|end of data|RCPT TO:\S+|MAIL FROM:\S+|pipelined DATA|DATA): host (\S+ \S+): .+)';
    my $defer_maildir_regex='defer \(-?\d+\): (mailbox is full .+)';
    my $reject_regex='(SMTP error from remote mail server after (?:initial commection|end of data|RCPT TO:\S+|MAIL FROM:\S+|pipelined DATA|DATA): host (\S+ \S+): .+)';
    my $email_regex='([^@]+\@[\S]+)';
    my $host_in3_regex='(\S+) \([\w._-]+\)( \[[\d.]+\])';
    my $host_in2_regex='\(\S+\) (\[[\d.]+\])';
    my $host_out2_regex='(\S+ \[[\d.]+\])\*?';
    my $host_in2b_regex=$host_out2_regex;
    my $maildir_regex='(/\S+/)';
    my $mailqid_regex='([\w-]{16})';
    my $rbl_regex='(\d+\..* is listed at .*|Blocked by internal RBL.*postmaster\.ivenue\.com.*)';
    my $size_regex='(\d+)';
    my $spam_score_regex='scored ([\d-]+\.\d) points';
    my $rfc_2822_regex='(RFC 2822.*MUST.*)';
    my $spf_regex='SPF ((?:PASS|BLOCK|DEFER|ALLOW).+)';

    if ( $line =~ s/$mailqid_regex // ) {
        $mailqId=$1;
    } else {
        $mailqId=( $date || $spam->{'date'} || $rfc_2822->{'date'} ) . "_" . $hostname;
        $mailqId =~ s/ /_/;
    }

    $mailqId  = &dbh->quote( $mailqId );
    $qdate    = &dbh->quote( $date );

    # Now we start figuring out what the meat of the line is
    # Detect email from a host that reverse resolves
    if ( $line =~ m/^<= $email_regex H=$host_in3_regex .+ S=$size_regex/ ) {
        my $mailFrom=&dbh->quote( $1 );
        my $relayIn =&dbh->quote( $2 . $3 );
        my $mailSize=&dbh->quote( $4 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailSize,mailSPFStatus,mailInRelay) ";
        $query   .=              "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$mailSize,$mailSPFStatus,$relayIn)";
        &dodbh( $query );
    }
    # Detect email from a host that does not reverse resolve
    elsif ( $line =~ m/^<= $email_regex H=$host_in2_regex .+ S=$size_regex/ ) {
        my $mailFrom=&dbh->quote( $1 );
        my $relayIn =&dbh->quote( $2 );
        my $mailSize=&dbh->quote( $3 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailSize,mailSPFStatus,mailInRelay) ";
        $query   .=              "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$mailSize,$mailSPFStatus,$relayIn)";
        &dodbh( $query );
    }
    # Detect email from a host that does reverse resolve and matches who it said it was
    elsif ( $line =~ m/^<= $email_regex H=$host_in2b_regex .+ S=$size_regex/ ) {
        my $mailFrom=&dbh->quote( $1 );
        my $relayIn =&dbh->quote( $2 );
        my $mailSize=&dbh->quote( $3 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailSize,mailSPFStatus,mailInRelay) ";
        $query   .=              "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$mailSize,$mailSPFStatus,$relayIn)";
        &dodbh( $query );
    }
    # Detect email to a remote user (forwarded)
    elsif ( $line =~ m/^[=-]> $email_regex(?: P=<\S+>)? R=\S+ T=remote_smtp\S*.* H=$host_out2_regex .*C="(.*)"/ ) {
        my $mailTo=&preparedMailTo($1);
        my $mailOutRelay=&dbh->quote( $2 );
        my $mailSendStatus=&dbh->quote( $3 );
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=             "VALUES ($mailqId,$mailTo,$qdate,$mailOutRelay,$mailSendStatus)";
        &dodbh( $query );
    }
    # Detect email to a remote user (forwarded second format)
    elsif ( $line =~ m/^[=-]> $email_regex <$email_regex>(?: P=<\S+>)? R=\S+ T=remote_smtp\S*.* H=$host_out2_regex .*C="(.*)"/ ) {
        my $mailForwardedTo=&preparedMailTo($1);
        my $mailTo=&preparedMailTo($2);
        my $mailOutRelay=&dbh->quote( $3 );
        my $mailSendStatus=&dbh->quote( $4 );
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailForwardedTo,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=             "VALUES ($mailqId,$mailTo,$mailForwardedTo,$qdate,$mailOutRelay,$mailSendStatus)";
        &dodbh( $query );
    }
    # Detect email delivered to a local user
    elsif ( $line =~ m#^[=-]> $maildir_regex \($email_regex\) <$email_regex>(?: P=<\S+>)? R=virtual_user# ) {
        my $localMailer=&dbh->quote( $1 );
        my $mailTo=&preparedMailTo($2);
        my $mailAlias=&dbh->quote( $3 );
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailAlias,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=             "VALUES ($mailqId,$mailTo,$mailAlias,$qdate,$localMailer,'Completed')";
        &dodbh( $query );
    }
    # Detect email delivered to a local user (second format)
    elsif ( $line =~ m#^[=-]> $maildir_regex <$email_regex>(?: P=<\S+>)? R=virtual_user# ) {
        my $localMailer=&dbh->quote( $1 );
        my $mailTo=&preparedMailTo($2);
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=             "VALUES ($mailqId,$mailTo,$qdate,$localMailer,'Completed')";
        &dodbh( $query );
    }
    # Detect email that is deferred because unable to deliver to a local user
    elsif ( $line =~ m/^== $maildir_regex <$email_regex> R=\S+ T=address_directory $defer_maildir_regex/ ) {
        my $localMailer=&dbh->quote( $1 );
        my $mailTo=&preparedMailTo($2);
        my $mailSendStatus=&dbh->quote( $3 );
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=             "VALUES ($mailqId,$mailTo,$qdate,$localMailer,$mailSendStatus)";
        &dodbh( $query );
    }
    # Detect email that is deferred because unable to deliver to remote smtp server
    elsif ( $line =~ m/^== $email_regex <$email_regex>(?: P=<\S+>) R=\S+ T=remote_smtp\S* $defer_regex/ ) {
        my $mailTo         = &preparedMailTo($1);
        my $mailFrom       = &dbh->quote( $2 );
        my $mailSendStatus = &dbh->quote( $3 );
        my $mailOutRelay   = &dbh->quote( $4 );
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=               "VALUES ($mailqId,$mailTo,$qdate,$mailOutRelay,$mailSendStatus)";
        &dodbh( $query );
    }
    # Detect email that is rejected because unable to deliver to remote smtp server
    elsif ( $line =~ m/^\*\* $email_regex (?:<\S+> )?P=<$email_regex> R=\S+ T=remote_smtp\S* $reject_regex/ ) {
        my $mailTo         = &preparedMailTo($1);
        my $mailFrom       = &dbh->quote( $2 );
        my $mailSendStatus = &dbh->quote( $3 );
        my $mailOutRelay   = &dbh->quote( $4 );
        my $query = "INSERT INTO $mailOut (mailqId,mailTo,mailDateSent,mailOutRelay,mailSendStatus) ";
        $query   .=               "VALUES ($mailqId,$mailTo,$qdate,$mailOutRelay,$mailSendStatus)";
        &dodbh( $query );
    }
    # Detect SPF status of an email
    elsif ( !$opts{'rejects'} && $line =~ m/^H=.+ $spf_regex/ ) {
        $spf->{$mailqId} = &dbh->quote( $1 );
        push(@{$spf->{'ids'}},$mailqId);
        if ( scalar @{$spf->{'ids'}} > 1000 ) {
            # Garbage collection, get rid of oldest
            shift(@{$spf->{'ids'}});
        }
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in3_regex F=<$email_regex> .+DATA:.+$spf_regex/ ) {
        my $relayIn  =&dbh->quote( $1 . $2 );
        my $mailFrom =&dbh->quote( $3 );
        my $mailSPFStatus=&dbh->quote( $4 );
        my $mailReceiveStatus=&dbh->quote("Blocked by SPF");
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in2_regex F=<$email_regex> .+DATA:.+$spf_regex/ ) {
        my $relayIn  =&dbh->quote( $1 );
        my $mailFrom =&dbh->quote( $2 );
        my $mailSPFStatus=&dbh->quote( $3 );
        my $mailReceiveStatus=&dbh->quote("Blocked by SPF");
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in2b_regex F=<$email_regex> .+DATA:.+$spf_regex/ ) {
        my $relayIn  =&dbh->quote( $1 );
        my $mailFrom =&dbh->quote( $2 );
        my $mailSPFStatus=&dbh->quote( $3 );
        my $mailReceiveStatus=&dbh->quote("Blocked by SPF");
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in3_regex F=<$email_regex> rejected after DATA:.+$spam_score_regex/ ) {
        my $relayIn  =&dbh->quote( $1 . $2 );
        my $mailFrom =&dbh->quote( $3 );
        my $spamScore=&dbh->quote( $4 );
        my $mailReceiveStatus=&dbh->quote("Blocked by SpamAssassin");
        my $mailSPFStatus=&getSPFStatus($mailqId);
        $step++;
        $spam->{'date'} = &dbh->quote( $date );
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailSpamScore,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$spamScore,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in2_regex F=<$email_regex> rejected after DATA:.+$spam_score_regex/ ) {
        my $relayIn  =&dbh->quote( $1 );
        my $mailFrom =&dbh->quote( $2 );
        my $spamScore=&dbh->quote( $3 );
        my $mailReceiveStatus=&dbh->quote("Blocked by SpamAssassin");
        my $mailSPFStatus=&getSPFStatus($mailqId);
        $step++;
        $spam->{'date'} = &dbh->quote( $date );
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailSpamScore,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$spamScore,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in2b_regex F=<$email_regex> rejected after DATA:.+$spam_score_regex/ ) {
        my $relayIn  =&dbh->quote( $1 );
        my $mailFrom =&dbh->quote( $2 );
        my $spamScore=&dbh->quote( $3 );
        my $mailReceiveStatus=&dbh->quote("Blocked by SpamAssassin");
        my $mailSPFStatus=&getSPFStatus($mailqId);
        $step++;
        $spam->{'date'} = &dbh->quote( $date );
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailSpamScore,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$spamScore,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in3_regex F=<$email_regex> rejected after DATA:.+$rfc_2822_regex/ ) {
        my $relayIn  =&dbh->quote( $1 . $2 );
        my $mailFrom =&dbh->quote( $3 );
        my $mailReceiveStatus=&dbh->quote( 'Rejected: '.$4 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        $rfc_2822->{'mailSendStatus'} = $mailReceiveStatus;
        $rfc_2822->{'date'}           = &dbh->quote( $date );
        $rfc_step++;
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in2_regex F=<$email_regex> rejected after DATA:.+$rfc_2822_regex/ ) {
        my $relayIn  =&dbh->quote( $1 );
        my $mailFrom =&dbh->quote( $2 );
        my $mailReceiveStatus=&dbh->quote( 'Rejected: '.$3 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        $rfc_2822->{'mailSendStatus'} = $mailReceiveStatus;
        $rfc_2822->{'date'}           = &dbh->quote( $date );
        $rfc_step++;
        print "2 host match, counter is $rfc_step\n" if ( $opts{'debug'} );
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( $opts{'rejects'} && $line =~ m/^H=$host_in2b_regex F=<$email_regex> rejected after DATA:.+$rfc_2822_regex/ ) {
        my $relayIn  =&dbh->quote( $1 );
        my $mailFrom =&dbh->quote( $2 );
        my $mailReceiveStatus=&dbh->quote( 'Rejected: '.$3 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        $rfc_2822->{'mailSendStatus'} = $mailReceiveStatus;
        $rfc_2822->{'date'}           = &dbh->quote( $date );
        $rfc_step++;
        my $query = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query   .=                "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( !$opts{'rejects'} && $line =~ m/^H=$host_in2_regex F=<$email_regex> rejected RCPT <$email_regex>: $rbl_regex/ ) {
        my $relayIn=&dbh->quote( $1 );
        my $mailFrom=&dbh->quote( $2 );
        my $mailTo=&preparedMailTo($3);
        my $mailRBLStatus=&dbh->quote( $4 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailOut (mailqId,mailTo,mailDateSent,mailRBLStatus,mailSendStatus) ";
        $query   .=              "VALUES ($mailqId,$mailTo,$qdate,$mailRBLStatus,'RBL Blocked')";
        &dodbh( $query );
        $query  = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query .=               "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,'RBL Blocked',$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( !$opts{'rejects'} && $line =~ m/^H=$host_in2b_regex F=<$email_regex> rejected RCPT <$email_regex>: $rbl_regex/ ) {
        my $relayIn=&dbh->quote( $1 );
        my $mailFrom=&dbh->quote( $2 );
        my $mailTo=&preparedMailTo($3);
        my $mailRBLStatus=&dbh->quote( $4 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailOut (mailqId,mailTo,mailDateSent,mailRBLStatus,mailSendStatus) ";
        $query   .=              "VALUES ($mailqId,$mailTo,$qdate,$mailRBLStatus,'RBL Blocked')";
        &dodbh( $query );
        $query  = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query .=               "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,'RBL Blocked',$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( !$opts{'rejects'} && $line =~ m/^H=$host_in3_regex F=<$email_regex> rejected RCPT <$email_regex>: $rbl_regex/ ) {
        my $relayIn=&dbh->quote( $1 . $2 );
        my $mailFrom=&dbh->quote( $3 );
        my $mailTo=&preparedMailTo($4);
        my $mailRBLStatus=&dbh->quote( $5 );
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailOut (mailqId,mailTo,mailDateSent,mailRBLStatus,mailSendStatus) ";
        $query   .=              "VALUES ($mailqId,$mailTo,$qdate,$mailRBLStatus,'RBL Blocked')";
        &dodbh( $query );
        $query  = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query .=               "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,'RBL Blocked',$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( !$opts{'rejects'} && $line =~ m/^H=$host_in2_regex F=<$email_regex> $bad_mime_regex T=$email_regex/ ) {
        my $relayIn=&dbh->quote( $1 );
        my $mailFrom=&dbh->quote( $2 );
        my $mailReceiveStatus=&dbh->quote( $3 );
        my $mailTo=&preparedMailTo($4);
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailOut (mailqId,mailTo,mailDateSent) ";
        $query   .=              "VALUES ($mailqId,$mailTo,$qdate)";
        &dodbh( $query );
        $query  = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query .=               "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    elsif ( !$opts{'rejects'} && $line =~ m/^H=$host_in3_regex F=<$email_regex> $bad_mime_regex T=$email_regex/ ) {
        my $relayIn=&dbh->quote( $1 . $2 );
        my $mailFrom=&dbh->quote( $3 );
        my $mailReceiveStatus=&dbh->quote( $4 );
        my $mailTo=&preparedMailTo($5);
        my $mailSPFStatus=&getSPFStatus($mailqId);
        my $query = "REPLACE INTO $mailOut (mailqId,mailTo,mailDateSent) ";
        $query   .=              "VALUES ($mailqId,$mailTo,$qdate)";
        &dodbh( $query );
        $query  = "REPLACE INTO $mailIn (mailqId,mailDateReceived,mailHost,mailFrom,mailInRelay,mailReceiveStatus,mailSPFStatus) ";
        $query .=               "VALUES ($mailqId,$qdate,$qhostname,$mailFrom,$relayIn,$mailReceiveStatus,$mailSPFStatus)";
        &dodbh( $query );
    }
    if ( $opts{'rejects'} ) {
        # Ugly hack to extract sender and spam scores from spamassassin output in reject log
        if ( $step == 1 && $line =~ /^P Received: from (.+)/ ) { 
            $spam->{'mailInRelay'} = &dbh->quote( $1 );
            print "**** Found mailInRelay " . $spam->{'mailInRelay'} . " in step $step\n" if ( $opts{'debug'} );
            $step++;
        }
        elsif ( $step == 2 && $line =~ /^\tby m.ivenue.com/ ) {
            print "**** step $step detected our mail server\n" if ( $opts{'debug'} );
            $step++;
        }
        elsif ( $step == 3 && $line =~ /^\t\(envelope-from <$email_regex>\)/ ) {
            $spam->{'mailFrom'} = &dbh->quote( $1 );
            print "**** Found mailFrom " . $spam->{'mailFrom'} . " in step $step\n" if ( $opts{'debug'} );
        }
        elsif ( $step == 3 && $line =~ /^\tid $mailqid_regex/ ) {
            $spam->{'mailqId'} = &dbh->quote( $1 );
            print "**** Found mailqId " . $1 . " in step " . $step . "\n" if ( $opts{'debug'} );
            $step++;
        }
        elsif ( $step == 4 && $line =~ /^\tfor $email_regex/ ) {
            $spam->{'mailTo'} = &dbh->quote( $1 );
            print "**** Found mailTo " . $spam->{'mailTo'} . " in step $step\n" if ( $opts{'debug'} );
            $step++;
        }
        elsif ( $step == 5 && $line =~ /^  X-Spam-Report:/ ) {
            print "**** step $step detected X-Spam-Report header\n" if ( $opts{'debug'} );
            $step++;
        }
        elsif ( $step == 6 && $line =~ /^\s+----/ ) {
            print "**** step $step detected template header\n" if ( $opts{'debug'} );
            $step++;
        }
        # Here's where the report starts
        elsif ( $step == 7 && $line =~ /^\s+/ ) {
            $spam->{'spamReport'} .= $line . "\n";
            print "**** Detected part of spam report at step $step\n$line\n" if ( $opts{'debug'} );
        }
        elsif ( $step == 7 ) {
            $step=0;
            $spam->{'mailSendStatus'} = &dbh->quote( 'Blocked by SpamAssassin' );
            $spam->{'spamReport'} = ( "\n" . $spam->{'spamReport'} ) if ( $spam->{'spamReport'} );
            $spam->{'spamReport'} = &dbh->quote( $spam->{'spamReport'} );
            my $query = "UPDATE $mailIn SET mailSpamReport=" . $spam->{'spamReport'};
            $query   .= " WHERE mailqId=" . $spam->{'mailqId'};
            &dodbh( $query );
            $query = "REPLACE INTO $mailOut (mailqId,mailDateSent,mailTo,mailSendStatus) ";
            $query .= "VALUES (" . $spam->{'mailqId'} . "," . $spam->{'date'} . "," ;
            $query .=              $spam->{'mailFrom'} . "," . $spam->{'mailSendStatus'} . ")";
            &dodbh( $query );
            $spam = {};
            print "**** Detected end of spam report\n" if ( $opts{'debug'} );
        }
        elsif ( $step == 5 && $line !~ /^\S?\s+/ ) {
            print Dumper $spam if ( $opts{'debug'} );
            $step = 0;
            $spam = {};
        }
        else {
             print "NO MATCH($step): $line\n" if ( $opts{'debug'} );
             $step = 0 if ($step > 7);
        }

        if ( $rfc_step == 1 && $line =~ /^P Received: from (.+)/ ) { 
            $rfc_2822->{'mailInRelay'} = &dbh->quote( $1 );
            $rfc_step++;
        }
        elsif ( $rfc_step == 2 && $line =~ /^\tby m.ivenue.com/ ) {
            $rfc_step++;
        }
        elsif ( $rfc_step == 3 && $line =~ /^\t\(envelope-from <$email_regex>\)/ ) {
            $rfc_2822->{'mailFrom'} = &dbh->quote( $1 );
        }
        elsif ( $rfc_step == 3 && $line =~ /^\tid $mailqid_regex/ ) {
            $rfc_2822->{'mailqId'} = &dbh->quote( $1 );
            print "**** Found mailqId " . $1 . " in RFC step " . $rfc_step . "\n" if ( $opts{'debug'} );
            $rfc_step++;
        }
        elsif ( $rfc_step == 4 && $line =~ /^\tfor $email_regex/ ) {
            $rfc_2822->{'mailTo'} = &dbh->quote( $1 );
            $rfc_step++;
        }
        elsif ( $rfc_step == 5 ) {
            $rfc_step=0;
            my $query = "REPLACE INTO $mailOut (mailqId,mailDateSent,mailTo,mailSendStatus) ";
            $query .= "VALUES (" . $rfc_2822->{'mailqId'} . "," . $rfc_2822->{'date'} . "," ;
            $query .=              $rfc_2822->{'mailTo'} . "," . $rfc_2822->{'mailSendStatus'} . ")";
            &dodbh( $query );
            $rfc_2822 = {};
            print "**** Detected end of header concerning RFC 2822 rejection\n" if ( $opts{'debug'} );
        }
        else {
            # print $line if ( $opts{'debug'} );
        }
            
    } else {
        $step = 0; $rfc_step = 0;
        $spam = {}; $rfc_2822 = {};
    }
}

sub preparedMailTo {
    my $mailTo = shift() || '';
    $mailTo =~ s/<>/MAILER-DAEMON/;
    $mailTo =~ s/[<>]//g;
    return(&dbh->quote( $mailTo ));
}

sub getSPFStatus {
    my $mailqId = shift();
    my $val = '';
    if ( $spf->{$mailqId} ) {
        $val = $spf->{$mailqId};
        delete $spf->{$mailqId};
    }
    return(&dbh->quote( $val ));
}

# vim: expandtab ts=4
