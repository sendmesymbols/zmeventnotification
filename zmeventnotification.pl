#!/usr/bin/perl -T
#
# ==========================================================================
#
# THIS SCRIPT MUST BE RUN WITH SUDO OR STARTED VIA ZMDC.PL
#
# ZoneMinder Realtime Notification System
#
# A  light weight event notification daemon
# Uses shared memory to detect new events (polls SHM)
# Also opens a websocket connection at a configurable port
# so events can be reported
# Any client can connect to this web socket and handle it further
# for example, send it out via APNS/GCM or any other mechanism
#
# This is a much  faster and low overhead method compared to zmfilter
# as there is no DB overhead nor SQL searches for event matches

# ~ PP
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================


#sudo perl -MCPAN -e "install Crypt::MySQL"
#sudo perl -MCPAN -e "install Net::WebSocket::Server"

#For iOS APNS:
#sudo perl -MCPAN -e "install Net::APNS::Persistent"

use Data::Dumper;
use File::Basename;

use strict;
use bytes;
# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================
use constant EVENT_NOTIFICATION_PORT=>9000; 				# port for Websockets connection
use constant SSL_CERT_FILE=>'/etc/apache2/ssl/zoneminder.crt';		# Change these to your certs/keys
use constant SSL_KEY_FILE=>'/etc/apache2/ssl/zoneminder.key';
use constant SLEEP_DELAY=>5; 						# duration in seconds after which we will check for new events
use constant MONITOR_RELOAD_INTERVAL => 300;
use constant WEBSOCKET_AUTH_DELAY => 20; 				# max seconds by which authentication must be done


my $useAPNS = 0;				# set this to 1 if you have an APNS SSL certificate/key pair
						# the only way to have this is if you have an apple developer
						# account

#----------- Start: If you have disabled APNS, ignore this --

my $isSandbox = 1;				# 1 or 0 depending on your APNS certificate


use constant APNS_CERT_FILE=>'/etc/private/apns-dev-cert.pem';
use constant APNS_KEY_FILE=>'/etc/private/apns-dev-key.pem';
use constant APNS_TOKEN_FILE=>'/etc/private/tokens.txt'; # MAKE SURE THIS DIRECTORY HAS WWW-DATA PERMISSIONS
use constant APNS_FEEDBACK_CHECK_INTERVAL => 3600;

#----------- End: If you have disabled APNS, ignore this --

use constant APP_VERSION=>'0.2';
use constant PENDING_WEBSOCKET => '1';
use constant INVALID_WEBSOCKET => '-1';
use constant INVALID_APNS => '-2';
use constant VALID_WEBSOCKET => '0';

if (!try_use ("Net::WebSocket::Server")) {Fatal ("Net::WebSocket::Server missing");exit (-1);}
if (!try_use ("IO::Socket::SSL")) {Fatal ("IO::Socket::SSL  missing");exit (-1);}
if (!try_use ("Crypt::MySQL qw(password password41)")) {Fatal ("Crypt::MySQL  missing");exit (-1);}

if (!try_use ("JSON")) 
{ 
	if (!try_use ("JSON::XS")) 
	{ Fatal ("JSON or JSON::XS  missing");exit (-1);}
} 

# These modules are needed only if APNS is enabled
if ($useAPNS)
{
	if (!try_use ("Net::APNS::Persistent") || !try_use ("Net::APNS::Feedback"))
	{
		Warning ("Net::APNS::Feedback and/or Net::APNS::Persistent not present. Disabling APNS support");
		$useAPNS = 0;

	}
	else
	{
		Info ("APNS support loaded");
	}
}
else
{
		Info ("APNS support disabled");
}

# ==========================================================================
#
# Don't change anything below here
#
# ==========================================================================

use lib '/usr/local/lib/x86_64-linux-gnu/perl5';
use ZoneMinder;
use POSIX;
use DBI;

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

sub Usage
{
    	print( "This daemon is not meant to be invoked from command line\n");
	exit( -1 );
}

logInit();
logSetSignal();

Info( "Event Notification daemon  starting\n" );

my $dbh = zmDbConnect();
my %monitors;
my $monitor_reload_time = 0;
my $apns_feedback_time = 0;
my $wss;
my @events=();
my @active_connections=();
my $alarm_header="";

# MAIN

if ($useAPNS)
{
	my $dir = dirname(APNS_TOKEN_FILE);
	if ( ! -d $dir)
	{

		Info ("Creating $dir to store APNS tokens");
		mkdir $dir;
	}
}

loadTokens();
initSocketServer();
Info( "Event Notification daemon exiting\n" );
exit();

# Try to load a perl module
# and if it is not available 
# generate a log 

sub try_use 
{
  my $module = shift;
  eval("use $module");
  return($@ ? 0:1);
}


# This function uses shared memory polling to check if 
# ZM reported any new events. If it does find events
# then the details are packaged into the events array
# so they can be JSONified and sent out
sub checkEvents()
{
	
	#foreach (@active_connections)
	#{
		#print " IP:".$_->{conn}->ip().":".$_->{conn}->port()."Token:".$_->{token}."\n";
	#}

	my $eventFound = 0;
	if ( (time() - $monitor_reload_time) > MONITOR_RELOAD_INTERVAL )
    	{
		my $len = scalar @active_connections;
		Info ("Total event client connections: ".$len."\n");

		Info ("Reloading Monitors...\n");
		foreach my $monitor (values(%monitors))
		{
			zmMemInvalidate( $monitor );
		}
		loadMonitors();
	}


	@events = ();
	$alarm_header = "";
	foreach my $monitor ( values(%monitors) )
	{ 
		my ( $state, $last_event )
		    = zmMemRead( $monitor,
				 [ "shared_data:state",
				   "shared_data:last_event"
				 ]
		);
		if ($state == STATE_ALARM || $state == STATE_ALERT)
		{
			if ( !defined($monitor->{LastEvent})
                 	     || ($last_event != $monitor->{LastEvent}))
			{
				Info( "New event $last_event reported for ".$monitor->{Name}."\n");
				$monitor->{LastState} = $state;
				$monitor->{LastEvent} = $last_event;
				my $name = $monitor->{Name};
				my $mid = $monitor->{Id};
				my $eid = $last_event;
				push @events, {Name => $name, MonitorId => $mid, EventId => $last_event};
				$alarm_header = "Alarms: " if (!$alarm_header);
				$alarm_header = $alarm_header . $name .",";
				$eventFound = 1;
			}
			
		}
	}
	chop($alarm_header) if ($alarm_header);
	return ($eventFound);
}

# Refreshes list of monitors from DB
# 
sub loadMonitors
{
    Info( "Loading monitors\n" );
    $monitor_reload_time = time();

    my %new_monitors = ();

    my $sql = "SELECT * FROM Monitors
               WHERE find_in_set( Function, 'Modect,Mocord,Nodect' )"
    ;
    my $sth = $dbh->prepare_cached( $sql )
        or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute()
        or Fatal( "Can't execute: ".$sth->errstr() );
    while( my $monitor = $sth->fetchrow_hashref() )
    {
        next if ( !zmMemVerify( $monitor ) ); # Check shared memory ok

        if ( defined($monitors{$monitor->{Id}}->{LastState}) )
        {
            $monitor->{LastState} = $monitors{$monitor->{Id}}->{LastState};
        }
        else
        {
            $monitor->{LastState} = zmGetMonitorState( $monitor );
        }
        if ( defined($monitors{$monitor->{Id}}->{LastEvent}) )
        {
            $monitor->{LastEvent} = $monitors{$monitor->{Id}}->{LastEvent};
        }
        else
        {
            $monitor->{LastEvent} = zmGetLastEvent( $monitor );
        }
        $new_monitors{$monitor->{Id}} = $monitor;
    }
    %monitors = %new_monitors;
}

# This function compares the password provided over websockets
# to the password stored in the ZM MYSQL DB

sub validateZM
{
	my ($u,$p) = @_;
	return 0 if ( $u eq "" || $p eq "");
	my $sql = 'select Password from Users where Username=?';
	my $sth = $dbh->prepare_cached($sql)
	 or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $u )
	or Fatal( "Can't execute: ".$sth->errstr() );
	if (my ($state) = $sth->fetchrow_hashref())
	{
		my $encryptedPassword = password41($p);
		$sth->finish();
		return $state->{Password} eq $encryptedPassword ? 1:0; 
	}
	else
	{
		$sth->finish();
		return 0;
	}

}


# This function is called when an alarm
# needs to be transmitted over APNS
sub sendOverAPNS
{
  if (!$useAPNS)
  {
	Info ("Rejecting APNS request as daemon has APNS disabled");
	return;
  }

  my ($obj, $header, $str) = @_;
  my (%hash) = %{$str}; 
      
    my $apns = Net::APNS::Persistent->new({
    sandbox => $isSandbox,
    cert    => APNS_CERT_FILE,
    key     => APNS_KEY_FILE
  });

   $obj->{badge}++;
   $apns->queue_notification(
	    $obj->{token},
	    {
	      aps => {
		  alert => $header,
		  sound => 'default',
		  badge => $obj->{badge},
	      },
	      alarm_details => \%hash
	    });

  $apns->send_queue;
  $apns->disconnect;

}



# This function polls APNS Feedback
# to see if any entries need to be removed
sub apnsFeedbackCheck
{

	if ((time() - $apns_feedback_time) > APNS_FEEDBACK_CHECK_INTERVAL)
	{
		if (!$useAPNS)
		{
			Info ("Rejecting APNS Feedback request as daemon has APNS disabled");
			return;
		}

		Info ("Checking APNS Feedback\n");
		$apns_feedback_time = time();
		my $apnsfb = Net::APNS::Feedback->new({
		sandbox => $isSandbox,
		cert    => APNS_CERT_FILE,
		key     => APNS_KEY_FILE
	  	});
	  	my @feedback = $apnsfb->retrieve_feedback;


		foreach (@feedback[0]->[0])
		{
			my $delete_token = $_->{token};
			if ($delete_token != "")
			{
				deleteToken($delete_token);
				foreach(@active_connections)
				{
					if ($_->{token} eq $delete_token)
					{
						$_->{pending} = INVALID_APNS;
						Info ("Marking entry as invalid apns token: ". $delete_token."\n");
					}
				}
			}
		}
	}
}

# This runs at each tick to purge connections
# that are inactive or have had an error
# This also closes any connection that has not provided
# credentials in the time configured after opening a socket

sub checkConnection
{
	foreach (@active_connections)
	{
		my $curtime = time();
		if ($_->{pending} == PENDING_WEBSOCKET)
		{
			if ($curtime - $_->{time} > WEBSOCKET_AUTH_DELAY)
			{
			# What happens if auth is not provided but device token is registered?
			# It may still be a bogus token, so don't risk keeping connection stored
				if (exists $_->{conn})
				{
					my $conn = $_->{conn};
					Info ("Rejecting ".$conn->ip()." - authentication timeout");
					$_->{pending} = INVALID_WEBSOCKET;
					my $str = encode_json({status=>'Fail', reason => 'NOAUTH'});
					eval {$_->{conn}->send_utf8($str);};
					$_->{conn}->disconnect();
				}
			}
		}

	}
	@active_connections = grep { $_->{pending} != INVALID_WEBSOCKET } @active_connections;
	if ($useAPNS)
	{
		@active_connections = grep { $_->{pending} != INVALID_APNS } @active_connections;
	}
}

# This function  is called whenever we receive a message from a client

sub checkMessage
{
	my ($conn, $msg) = @_;	
	
	my $json_string = decode_json($msg);
	#print "Message:$msg\n";

	# This event type is when a command related to push notification is received
	if (($json_string->{'event'} eq "push") && !$useAPNS)
	{
		my $str = encode_json({status=>'Fail', reason => 'APNSDISABLED'});
		eval {$conn->send_utf8($str);};
		return;
	}
	elsif (($json_string->{'event'} eq "push") && $useAPNS)
	{
		if ($json_string->{'data'}->{'type'} eq "badge")
		{
			foreach (@active_connections)
			{
				if ((exists $_->{conn}) && ($_->{conn}->ip() eq $conn->ip())  &&
				    ($_->{conn}->port() eq $conn->port()))  
				{

					#print "Badge match, setting to 0\n";
					$_->{badge} = $json_string->{'data'}->{'badge'};
				}
			}
		}
		# This sub type is when a device token is registered
		if ($json_string->{'data'}->{'type'} eq "token")
		{
			
			foreach (@active_connections)
			{
				if ($_->{token} eq $json_string->{'data'}->{'token'}) 
				{
					if ( (!exists $_->{conn}) || ($_->{conn}->ip() ne $conn->ip() 
						&& $_->{conn}->port() ne $conn->port()))
					{
						$_->{pending} = INVALID_APNS;
						Info ("Duplicate token found, marking for deletion");

					}
				}
				elsif ( (exists $_->{conn}) && ($_->{conn}->ip() eq $conn->ip())  &&
				    ($_->{conn}->port() eq $conn->port()))  
				{
					$_->{token} = $json_string->{'data'}->{'token'};
					$_->{monlist} = "-1";
					Info ("Device token ".$_->{token}." stored for APNS");
					Info ("savetokens/token ".$_->{token}." ".$_->{monlist}."\n");
					my $emonlist = saveTokens($_->{token}, $_->{monlist});
					$_->{monlist} = $emonlist;


				}
			}

				
		}
		
	} # event = push
	elsif (($json_string->{'event'} eq "control") )
	{
		if  ($json_string->{'data'}->{'type'} eq "filter")
		{
			my $monlist = $json_string->{'data'}->{'monlist'};
			foreach (@active_connections)
			{
				if ((exists $_->{conn}) && ($_->{conn}->ip() eq $conn->ip())  &&
				    ($_->{conn}->port() eq $conn->port()))  
				{

					$_->{monlist} = $monlist;
					Info ("savetokens/control ".$_->{token}." ".$_->{monlist}."\n");
					saveTokens($_->{token}, $_->{monlist});	
				}
			}
		}	
		if  ($json_string->{'data'}->{'type'} eq "version")
		{
			foreach (@active_connections)
			{
				if ((exists $_->{conn}) && ($_->{conn}->ip() eq $conn->ip())  &&
				    ($_->{conn}->port() eq $conn->port()))  
				{
					my $str = encode_json({status=>'Success', reason => '', version => APP_VERSION});
					eval {$_->{conn}->send_utf8($str);};

				}
			}
		}

	} # event = control



	# This event type is when a command related to authorization is sent
	elsif ($json_string->{'event'} eq "auth")
	{
		my $uname = $json_string->{'data'}->{'user'};
		my $pwd = $json_string->{'data'}->{'password'};
	
		return if ($uname eq "" || $pwd eq "");
		foreach (@active_connections)
		{
			if ( (exists $_->{conn}) &&
			    ($_->{conn}->ip() eq $conn->ip())  &&
			    ($_->{conn}->port() eq $conn->port())  &&
			    ($_->{pending}==PENDING_WEBSOCKET))
			{
				if (!validateZM($uname,$pwd))
				{
					# bad username or password, so reject and mark for deletion
					my $str = encode_json({status=>'Fail', reason => 'BADAUTH'});
					eval {$_->{conn}->send_utf8($str);};
					Info("Bad authentication provided by ".$_->{conn}->ip());
					$_->{pending}=INVALID_WEBSOCKET;
				}
				else
				{


					# all good, connection auth was valid
					$_->{pending}=VALID_WEBSOCKET;
					$_->{token}='';
					my $str = encode_json({status=>'Success', reason => '', version => APP_VERSION});
					eval {$_->{conn}->send_utf8($str);};
					Info("Correct authentication provided by ".$_->{conn}->ip());
					
				}
			}
		}
	} # event = auth
	else
	{
					my $str = encode_json({status=>'Fail', reason => 'NOTSUPPORTED'});
					eval {$_->{conn}->send_utf8($str);};
	}
}

# This loads APNS tokens stored in a conf file
# This ensures even if the daemon dies and 
# restarts APNS tokens are maintained
# I also maintain monitor filter list
# so that APNS notifications will only be pushed
# for the monitors that are configured against
# that token 

sub loadTokens
{
	return if (!$useAPNS);
	if ( ! -f APNS_TOKEN_FILE)
	{
		open (my $foh, '>', APNS_TOKEN_FILE);
		Info ("Creating ".APNS_TOKEN_FILE);
		print $foh "";
		close ($foh);
	}
	
	open (my $fh, '<', APNS_TOKEN_FILE);
	chomp( my @lines = <$fh>);
	close ($fh);
	my @uniquetokens = uniq(@lines);

	open ($fh, '>', APNS_TOKEN_FILE);
	# This makes sure we rewrite the file with
	# unique tokens
	foreach(@uniquetokens)
	{
		next if ($_ eq "");
		print $fh "$_\n";
		my ($token, $monlist)  = split (":",$_);
		#print "load: PUSHING $row\n";
		push @active_connections, {
					   token => $token,
					   pending => VALID_WEBSOCKET,
					   time=>time(),
					   badge => 0,
					   monlist => $monlist,
					  };
		
	}
	close ($fh);
}

# This is called if the APNS feedback channel
# reports an invalid token. We also remove it from
# our token file
sub deleteToken
{
	my $dtoken = shift;
	return if (!$useAPNS);
	return if ( ! -f APNS_TOKEN_FILE);
	
	open (my $fh, '<', APNS_TOKEN_FILE);
	chomp( my @lines = <$fh>);
	close ($fh);
	my @uniquetokens = uniq(@lines);

	open ($fh, '>', APNS_TOKEN_FILE);

	foreach(@uniquetokens)
	{
		my ($token, $monlist)  = split (":",$_);
		next if ($_ eq "" || $token eq $dtoken);
		print $fh "$_\n";
		#print "delete: $row\n";
		push @active_connections, {
					   token => $token,
					   pending => VALID_WEBSOCKET,
					   time=>time(),
					   badge => 0,
					   monlist => $monlist,
					  };
		
	}
	close ($fh);
}

# When a client sends a token id,
# I store it in the file
# It can be sent multiple times, with or without
# monitor list, so I retain the old monitor
# list if its not supplied. In the case of zmNinja
# tokens are sent without monitor list when the registration
# id is received from apple, so we handle that situation

sub saveTokens
{
	my $stoken = shift;
	my $smonlist = shift;
	return if ($stoken eq "");
	open (my $fh, '<', APNS_TOKEN_FILE) || Fatal ("Cannot open for read".APNS_TOKEN_FILE);
	chomp( my @lines = <$fh>);
	close ($fh);
	my @uniquetokens = uniq(@lines);
	my $found = 0;
	open (my $fh, '>', APNS_TOKEN_FILE) || Fatal ("Cannot open for write ".APNS_TOKEN_FILE);
	foreach (@uniquetokens)
	{
		next if ($_ eq "");
		my ($token, $monlist)  = split (":",$_);
		if ($token eq $stoken)
		{
			$smonlist = $monlist if ($smonlist eq "-1");
			print $fh "$stoken:$smonlist\n";
			$found = 1;
		}
		else
		{
			print $fh "$token:$monlist\n";
		}

	}

	$smonlist = "" if ($smonlist eq "-1");
	
	print $fh "$stoken:$smonlist\n" if (!$found);
	close ($fh);
	#print "Saved Token $token to file\n";
	return $smonlist;
	
}

# This keeps the latest of any duplicate tokens
# we need to ignore monitor list when we do this
sub uniq 
{
	my %seen;
   	my @array = reverse @_; # we want the latest
	my @farray=();
	foreach (@array)
	{
		my ($token,$monlist) = split (":",$_);
		# not interested in monlist
		if (! $seen{$token}++ )
		{
			push @farray, "$token:$monlist";
		}
		 
		
	}
	return @farray;
	
	
}

# Checks if the monitor for which
# an alarm occurred is part of the monitor list
# for that connection
sub isInList
{
	my $monlist = shift;
	my $mid = shift;

	my @mids = split (',',$monlist);
	my $found = 0;
	foreach (@mids)
	{
		if ($mid eq $_)
		{
			$found = 1;
			last;
		}
	}
	return $found;
	
}

# This is really the main module
# It opens a WSS socket and keeps listening
sub initSocketServer
{
	checkEvents();

	my $ssl_server = IO::Socket::SSL->new(
      	      Listen        => 10,
	      LocalPort     => EVENT_NOTIFICATION_PORT,
	      Proto         => 'tcp',
	      Reuse	    => 1,
	      SSL_cert_file => SSL_CERT_FILE,
	      SSL_key_file  => SSL_KEY_FILE
	    ) or die "failed to listen: $!";

	Info ("Web Socket Event Server listening on port ".EVENT_NOTIFICATION_PORT."\n");

	$wss = Net::WebSocket::Server->new(
		listen => $ssl_server,
		tick_period => SLEEP_DELAY,
		on_tick => sub {
			checkConnection();
			apnsFeedbackCheck() if ($useAPNS);
			my $ac = scalar @active_connections;
			if (checkEvents())
			{
				Info ("Broadcasting new events to all $ac websocket clients\n");
					my ($serv) = @_;
					my $i = 0;
					foreach (@active_connections)
					{
						# Let's see if this connection is interested in this alarm
						my $monlist = $_->{monlist};

						# we need to create a per connection array which will be
						# a subset of main events with the ones that are not in its
						# monlist left out
						my @localevents = ();
						foreach (@events)
						{
							if ($monlist eq "" || isInList($monlist, $_->{MonitorId} ) )
							{
								push (@localevents, $_);
							}

						}
						#print "DUMPING " .Dumper(@localevents);
						# if this array is empty that means none of the alarms 
						# were generated from a monitor it is interested in
						next if (scalar @localevents == 0);

						my $str = encode_json({event => 'alarm', status=>'Success', events => \@localevents});
						my %hash_str = (event => 'alarm', status=>'Success', events => \@localevents);
						$i++;
						# if there is APNS send it over APNS
						# if not, send it over Websockets 
						if ($_->{token} ne "")
						{
							sendOverAPNS($_,$alarm_header, \%hash_str) ;
						}
						# if there is a websocket send it over websockets
						elsif ($_->{pending} == VALID_WEBSOCKET)
						{
							if (exists $_->{conn})
							{
								Info ($_->{conn}->ip()."-sending over websockets\n");
								eval {$_->{conn}->send_utf8($str);};
								if ($@)
								{
							
									$_->{pending} = INVALID_WEBSOCKET;
								}
							}
						}
						

						
					}


			}
		},
		# called when a new connection comes in
		on_connect => sub {
			my ($serv, $conn) = @_;
			my ($len) = scalar @active_connections;
			Info ("got a websocket connection from ".$conn->ip()." (". $len.") active connections");
			$conn->on(
				utf8 => sub {
					my ($conn, $msg) = @_;
					checkMessage($conn, $msg);
				},
				handshake => sub {
					my ($conn, $handshake) = @_;
					Info ("Websockets: New Connection Handshake requested from ".$conn->ip().":".$conn->port()." state=pending auth");
					my $connect_time = time();
					push @active_connections, {conn => $conn, 
								   pending => PENDING_WEBSOCKET, 
								   time=>$connect_time, 
								   monlist => "",
								   badge => 0};
				},
				disconnect => sub
				{
					my ($conn, $code, $reason) = @_;
					Info ("Websocket remotely disconnected from ".$conn->ip());
					foreach (@active_connections)
					{
						if ((exists $_->{conn}) && ($_->{conn}->ip() eq $conn->ip())  &&
                    				    ($_->{conn}->port() eq $conn->port()))
						{
							# mark this for deletion only if device token
							# not present
							if ( $_->{token} eq '')
							{
								$_->{pending}=INVALID_WEBSOCKET; 
								Info( "Marking ".$conn->ip()." for deletion as websocket closed remotely\n");
							}
							else
							{
								
								Info( "NOT Marking ".$conn->ip()." for deletion as token ".$_->{token}." active\n");
							}
						}

					}
				},
			);

			
		}
	)->start;
}
