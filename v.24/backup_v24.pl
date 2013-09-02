#!/usr/bin/perl -w
# Backup local mysql and dirs to sftp.
# 7/2013 lwintringham@psteering.com
use strict;
use MIME::Base64;
use Net::SFTP::Foreign;
use Fcntl ':mode';
use constant VERSION => 'Backup v.24';
use constant INFO => '(c) 2013 Lee Wintringham, PowerSteering by Upland';
#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#
# v.1 7/11/2013 First
# v.21 7/13/2013 Added File Size and better formatting. some error catching.
# v.22 7/13/2013 Much improved error handling.
# v.23 7/15/2013 Cleanup, tweaks and GPL'd.
# v.24 9/2/2013 Beta Encryption.
#
# DEPENDENCIES 
#   Net::SFTP::Foreign (libnet-sftp-foreign-perl)
#
# LICENSE
#  Copyright (C) 2013  Lee Wintringham, PowerSteering Software
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, version 3 of the License.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# INSTRUCTIONS
#
# 1. Set values for email report and SFTP credentials.
# 2. Add objects to the %items data structure. 
#   - Objects must have a valid 'type' attribute.
#   - Object names must be unique.
#   - Backups are processed alphabetically by object name.
#
#   'ObjectName' => {
#     type => 'value',
#     attribute => 'value', 
#    },
#
# OBJECT TYPES
#
# mysql - Backup a local MySQL database
#   Required Attributes:
#     type - Value must be 'mysql'
#     db - Database Name
#     user - Database User
#     pass - Database Password
#     encrypt - (Beta) Value is '1' for encrypt. '0' to disable.
#
# file - Backup a file or directory
#   Required Attributes:
#     type - Value must be 'file'
#     path - Path to file or directory
#     encrypt - (Beta) Value is '1' for encrypt. '0' to disable.
#
#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#
# Settings
my $from = 'backup@blah.com';			# Email From Address
my $recipient = 'blah@blah.com';		# Email Report Destination
my $returns = 'postmaster@blah.com';		# Email Bounce Address
my $subject = "backup report";			# Email Report Subject
my $logfile = 'log.tmp';			# Full path to log file
my $verbose = 1; 				# Verbose output. 1 On, 0 Off
my $printLog = 1;				# Email log output. 1 On, 0 Off
# Encryption Settings
my $cipher = 'aes-256-cbc';			# Encryption Cipher. Default aes-256-cbc
my $pass = 'XXXXXXXXXX';			# Encryption Password
# SFTP Creds
my $sftp_host = 'sftp.example.com';		# SFTP Server 
my $sftp_user = 'backup';			# SFTP User
my $sftp_pass = 'XXXXX';			# SFTP Password
my $sftp_dir = '/home/XXX/backup';		# SFTP Upload Directory
my $sftp_port = 22;				# SFTP Port
# Retention Policy
my $retention = '7';				# Days to keep backups on SFTP Server
# Holding Dir		
my $holdingdir = '/tmp';			# Local Temporary Holding Directory	
# Backup Objects
my %items = (
    'Forum' => {
      type => 'mysql',
      db => 'forum',
      user => 'root',
      pass => 'xxx',
      encrypt => 1,
    },
    'OtherDB' => {
      type => 'mysql',
      db => 'test',
      user => 'root',
      pass => 'xxx',
    },
    'emc_stuff' => {
      type => 'file',
      location => '/home/lee/EMC',
    },
    'documents' => {
      type => 'file',
      location => '/home/lee/Documents',
      encrypt => 1,
    },
    'things' => {
      type => 'file',
      location => '/home/lee/freetds',
    },
);
#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#~#
# Begin
my @report;
my @filelist;
my @errs;
my @dels;
my @log;
my $bgcolor;
my $num = 0;

open(LOG,">> $logfile") or die "Can't open $logfile $!";
logme(VERSION);
logme(INFO);

my $head = <<HEAD;
<html>
 <head>
 <style type=\"text/css\">
   h1 { font-family: arial,sans-serif; font-size: 18px; font-weight; bold; }
   h2 { font-family: arial,sans-serif; font-size: 16px; font-weight; bold; }
   td.header1 { background-color: #6090B7; padding-top: 5px; padding-bottom: 5px; font-weight: bold;}
   td.header2 { background-color: #FF0000; padding-top: 5px; padding-bottom: 5px; font-weight: bold;}
   td.fill1 { background-color: #c8c8c8; padding-top: 5px; padding-bottom: 5px;}
   td.fill2 { background-color: #e0e0e0; padding-top: 5px; padding-bottom: 5px;}
   td.green { background-color: #66CD00; padding-top: 5px; padding-bottom: 5px;}
   table { font-size: 14px; font-family: arial,sans-serif; border: 1px solid; border-collapse: collapse; width: 600px;}
   </style>
</head>
  <body>
  <h1>Backup Report</h1>
  <h2>Input Objects:</h2>
  <table>
  <tr> <td class=\"header1\">Object</td> <td class=\"header1\">Type</td> <td class=\"header1\">Encryption</td> <td class=\"header1\">Output</td> <td class=\"header1\">Size</td></tr>
HEAD

my $foot = <<FOOT;
 </body>
</html>
FOOT

push(@report,$head);

my $localtime = localtime time;
my (undef,$mon,$day,$time,$year) = split(/\s+/,$localtime);
$time =~ s/:/_/g;
my $tstamp = $mon . '-' . $day . '-' . $year . '-' . $time;

foreach my $name (sort keys %items) {
  if ($num % 2) {
    $bgcolor = 'fill1';
  } else {
    $bgcolor = 'fill2';
  }
  if ($items{$name}{'type'} =~ /mysql/) {
    backupMysql($name);
    if ($? == 0 ) {
      $num++;
    } else {
      logme("ERROR: Returned Exit Code $?");
    }
  } 
  elsif ($items{$name}{'type'} =~ /file/) {
    backupFile($name);
    if ($? == 0 ) {
      $num++;
    } else {
      logme("ERROR: Returned Exit Code $?");
    }
  }
  else {
    logme("ERROR: Invalid type definition in $name");
  }
}

sub backupMysql {
  my $name = shift;
  my $enc = 'No';
  logme("Executing MySQL Backup for: $name");
  my $mysqldb = $items{$name}{'db'};
  my $mysqluser = $items{$name}{'user'};
  my $mysqlpass = $items{$name}{'pass'};
  my $outfile = $name . '_' . $tstamp . '.sql'; 
  my $cmd = `mysqldump -u$mysqluser -p$mysqlpass $mysqldb > $holdingdir/$outfile`;
  if ( $? == 0) {
    logme("Mysqldump OK");
    system "gzip $holdingdir/$outfile";
    $outfile = $outfile . '.gz';
  } else {
    logme("ERROR: Mysql Backup ($name) Failed");
    return $?;
  }
  if ($items{$name}{'encrypt'} == 1) {
    enc("$holdingdir/$outfile");
    if ( $? != 0) {
      return;
    }
   $enc = 'Yes';
  }
  my $fileSize = getSize("$holdingdir/$outfile");
  push(@report,"<tr> <td class=\"$bgcolor\">$name</td> <td class=\"$bgcolor\">MySQL</td> <td class=\"$bgcolor\">$enc</td> <td class=\"$bgcolor\">$outfile</td> <td class=\"$bgcolor\">$fileSize</td> </tr>");
  push (@filelist,$outfile);
  return 0;
}

sub backupFile {
  my $name = shift;
  my $enc = 'No';
  logme("Executing File Backup for: $name");
  my $path = $items{$name}{'location'};
  my $outfile =  $name . '_' . $tstamp . '.tgz';
  system "tar czf $holdingdir/$outfile $path";
  if ( $? == 0) {
    logme("Archive OK");
  } else {
    logme("ERROR: Archive ($name) Failed");
    return 1;
  }
  if ($items{$name}{'encrypt'} == 1) {
    enc("$holdingdir/$outfile");
    if ($? != 0) {
      return;
    }
    $enc = 'Yes';
  }
  my $fileSize = getSize("$holdingdir/$outfile");
  push(@report,"<tr> <td class=\"$bgcolor\">$name</td> <td class=\"$bgcolor\">File</td> <td class=\"$bgcolor\">$enc</td> <td class=\"$bgcolor\">$outfile</td> <td class=\"$bgcolor\">$fileSize</td> </tr>");
  push (@filelist,$outfile);
  return 0;
}

sub logme {
  my $loginfo = shift;
  my $logtime = localtime time;
  my (undef, $month, $day, $time, $year) = split(/\s+/,$logtime);
  my $ts = "$month $day $time";
  if ($verbose == 1) {
    print "$loginfo\n";
  }	
  print LOG "[$ts] $loginfo\n";
  push(@log,"[$ts] $loginfo");
  if ($loginfo =~ /^ERROR/) {
    push(@errs,$loginfo);
  }
}

sub getSize {
  my $input = shift; 
  my $value = -s $input;
  if (length($value) >= 7) {
    #Report MB
    my $val_mb = ($value / 1024) / 1024;
    if ($val_mb =~ /(\d+)\.(\d{3,})/) {
      my $decmb = substr($2,0,2);
      $val_mb = $1 . '.' . $decmb;
     }
     return $val_mb . "MB";
  } else { 
    #Report KB
    my $val_kb = $value / 1024;
    if ($val_kb =~ /(\d+)\.(\d{3,})/) {
      my $deckb = substr($2,0,2);
      $val_kb = $1 . '.' . $deckb;
    }
    return $val_kb . "KB";
  }
}

sub enc {
  my $encInFile = shift;

  my $openssl = `which openssl`;
  if (!$openssl) { 
    logme("ERROR: openssl not found");
    return 1;
  }
  chomp $openssl;
  my $encOutFile = $encInFile . '.enctmp';
  my $opensslEnc = `$openssl $cipher -salt -in $encInFile -out $encOutFile -k $pass`;
  if ( $? == 0) {
    logme("Encrypt Success");
    my $shred = `which shred`;
    chomp $shred;
    if (!$shred) { 
      logme("WARNING: shred not found. Using unsecure delete.");
      my $run_rm = `rm -f $encInFile`;
    } else {
      logme("Securley Deleteing Source File");
      my $run_shred = `$shred -u $encInFile`;
    }
    rename($encOutFile, $encInFile);
  } else {
    logme("ERROR: Encryption ($encInFile) Failed");
    return 1;
  }
}

# Connect to SFTP
my $sftp = Net::SFTP::Foreign->new(
  host => $sftp_host,
  user => $sftp_user,
  password => $sftp_pass,
  port => $sftp_port,
  timeout => 60,
  #autoflush => 1,
  more => "-q"
) or logme("ERROR: $!");

$sftp->setcwd("$sftp_dir") or logme("ERROR: " . $sftp->error);

# Upload @filelist
foreach my $put_file (@filelist) {
  logme("Sending file $put_file");
  $sftp->put("$holdingdir/" . $put_file,$put_file) or logme("ERROR: " . $sftp->error);
  if (!$sftp->error) {
    unlink "$holdingdir/$put_file" or logme("ERROR: $!");
  } else {
    logme("ERROR: Keeping Local Copy: $holdingdir/$put_file");
  }
}

# Removed Expired Backups
logme("Checking for Expired Backups on remote host");
my $utime = time();
# Get list of remote files ignoring directories
my $remote_files = $sftp->ls("$sftp_dir", wanted => sub {S_ISREG($_[1]->{a}->perm);}) or logme("ERROR: " . $sftp->error);
foreach my $r_filename (@$remote_files) {
  next if ($r_filename->{filename} =~ /^\./);

  my $stat_file = $sftp_dir . "/$r_filename->{filename}";
  my $stat = $sftp->stat($stat_file);
  my $mtime = $stat->mtime;

  my $age_hours = int($utime - $mtime) / 3600;
  my $age_days  = int($age_hours / 24);

  if ($age_days >= $retention) {
    push(@dels,"Deleting $stat_file $age_days days old <br />");
    logme("Deleting $stat_file $age_days days old");
    $sftp->remove($stat_file) or logme("ERROR: " . $sftp->error . " $stat_file");
  } 
}

logme("Done");

my $eBody;
push (@report, "</table>");
push (@report, "<h2>Expired Backups:</h2>");
for (@dels) {
  push(@report,$_);
}
push (@report, "<h2>Errors:</h2>");
for(@errs) {
  push(@report,"$_<br />");
}

if ($printLog == 1) {
  push (@report, "<h2>Log Output:</h2>");
  for(@log) {
    push(@report,"$_<br />");
  }
}

push(@report,$foot);

for(@report) {
 $eBody .= "$_\n";
} 

my $eBody_b64 = encode_base64($eBody);

open( SENDMAIL, "| /usr/sbin/sendmail -oi -t -f $returns" );
#~# print SENDMAIL "Reply-To: $returns\n";
print SENDMAIL "From: $from\n";
print SENDMAIL "To: $recipient\n";
print SENDMAIL "Subject: $subject\n";
print SENDMAIL "Content-type: text/html\n";
print SENDMAIL "Content-Transfer-Encoding: base64\n\n";
print SENDMAIL $eBody_b64;
close SENDMAIL;

close LOG;
