##########################################################################
# Usage:
#
##########################################################################
# $Id: Matrix.pm 22821 2022-11-12 12:52:00Z Man-fred $
#
# from the developerpages:
# Verwendung von lowerCamelCaps für a) die Bezeichnungen der Behälter für Readings, Fhem und Helper und der Untereintraege, 
#                                   b) die Bezeichnungen der Readings, 
#                                   c) die Bezeichnungen der Attribute.

#package FHEM::Devices::Matrix;
#(Man-Fred) geh ich Recht in der Annahme, dass hier das gleiche package hin gehört
#           wie im Modul 98_Matrix?
package FHEM::Matrix;

use strict;
use warnings;
use HttpUtils;
use JSON;
use FHEM::Core::Authentication::Passwords qw(:ALL);

use experimental qw /switch/;		#(CoolTux) - als Ersatz für endlos lange elsif Abfragen

BEGIN {

  GP_Import(qw(
    readingsBeginUpdate
    readingsBulkUpdate
    readingsEndUpdate
    readingsSingleUpdate
    Log3
    defs
    init_done
	IsDisabled
	deviceEvents
    AttrVal
    ReadingsVal
    HttpUtils_NonblockingGet
    InternalTimer
	data
	gettimeofday
	fhem
  ))
};

my $Module_Version = '0.0.9';
my $language = 'EN';

sub Attr_List{
	return "matrixLogin:password matrixRoom matrixPoll:0,1 matrixSender matrixMessage matrixQuestion_ matrixQuestion_[0-9]+ matrixAnswer_ matrixAnswer_[0-9]+ $readingFnAttributes";
}

sub Define {
	#(CoolTux) bei einfachen übergaben nimmt man die Daten mit shift auf
    my $hash	= shift;
	my $def 	= shift;

    my @param = split('[ \t]+', $def);
	my $name = $param[0]; #$param[0];
	
    Log3($name, 1, "$name: Define: $param[2] ".int(@param)); 

    if(int(@param) < 1) {
        return "too few parameters: define <name> Matrix <server> <user>";
    }

    $hash->{name}  = $param[0];
    $hash->{server} = $param[2];
    $hash->{user} = $param[3];
    $hash->{password} = $param[4];
    $hash->{helper}->{passwdobj} = FHEM::Core::Authentication::Passwords->new($hash->{TYPE});
	#$hash->{helper}->{i18} = Get_I18n();
	$hash->{NOTIFYDEV} = "global";

	Startproc($hash) if($init_done);		#(CoolTux) Wie startet Startproc() wenn $init_done 0 ist. Dann bleibt das Modul stehen und macht nichts mehr
											#  es empfiehlt sich hier in der NotifyFn das globale Event INITIALIZED abzufangen.
											#  Ok gerade gesehen hast Du gemacht!!!

    return ;
}

sub Undef {
    my $hash	= shift;
	my $arg		= shift;

    my $name = $hash->{NAME};
    # undef $data
	# $data{MATRIX}{"$name"} = undef;					#(CoolTux) Bin mir gerade nicht sicher woher das $data kommt
														#  meinst Du das %data aus main? Das ist für User. Wenn Du als Modulentwickler
														#  etwas zwischenspeichern möchtest dann in $hash->{helper}

    $hash->{helper}->{passwdobj}->setDeletePassword($name);			#(CoolTux) das ist nicht nötig, 
																	#  du löschst jedesmal den Eintrag wenn FHEM beendet wird.
																	#  Es sollte eine DeleteFn geben da kannst Du das rein machen

    return ;
}

sub Startproc {
	my $hash = shift;

	my $name = $hash->{NAME};

	Log3($name, 4, "$name : Matrix::Startproc $hash ".AttrVal($name,'matrixPoll','-1'));
	# Update necessary?
    Log3($name, 1, "$name: Start V".$hash->{ModuleVersion}." -> V".$Module_Version) if ($hash->{ModuleVersion});

	$hash->{ModuleVersion} = $Module_Version;   
	$language = AttrVal('global','language','EN');
	$hash->{helper}->{"softfail"} = 1;

	Login($hash) if (AttrVal($name,'matrixPoll',0) == 1);

	return;
}

sub Login {
	my $hash = shift;

	Log3($hash->{NAME}, 4, "$hash->{NAME} : Matrix::Login $hash");

	return PerformHttpRequest($hash, 'login', '');
}

##########################
# sub Notify($$)				
				#(CoolTux) Subroutine prototypes used. See page 194 of PBP (Subroutines::ProhibitSubroutinePrototypes)
				# Contrary to common belief, subroutine prototypes do not enable
				# compile-time checks for proper arguments. Don't use them.
sub Notify
{
	my $hash	= shift;
	my $dev		= shift;

	my $name = $hash->{NAME};
	my $devName = $dev->{NAME};

	return "" if(IsDisabled($name));

	my $events = deviceEvents($dev,1);

	return if( !$events );

	#if(($devName eq "global") && grep(m/^INITIALIZED|REREADCFG$/, @{$events}))
	  #(CoolTux) unnötige Klammern, und vielleicht bisschen übersichtlicher versuchen :-)
	if ( $devName eq "global"
	  && grep(m/^INITIALIZED|REREADCFG$/, @{$events}))
	{
		Log3($name, 4, "$name : Matrix::Notify $hash");
		Startproc($hash);
	}


		#(CoolTux) bin mir nicht sicher wieso die Schleife. Nötig ist sie aber egal wofür gedacht nicht.
		#(Man-Fred) die Schleife ist vom Debugging, ich wollte wissen was im Notify ankommt.
		#           kann raus in einer späteren Version
	foreach my $event (@{$events}) {
		$event = "" if(!defined($event));
		### Writing log entry
		Log3($name, 4, "$name : Matrix::Notify $devName - $event");
		$language = AttrVal('global','language','EN') if ($event =~ /ATTR global language.*/);
		# Examples:
		# $event = "ATTR global language DE"
		# $event = "readingname: value" 
		# or
		# $event = "INITIALIZED" (for $devName equal "global")
		#
		# processing $event with further code
	}

	return;		#(CoolTux) es reicht nur return. Wichtig jede sub muss immer mit return enden
}

#############################################################################################
# called when the device gets renamed, copy from telegramBot
# in this case we then also need to rename the key in the token store and ensure it is recoded with new name
sub Rename {
    my $new	= shift;
	my $old = shift;

	my $hash = $defs{$new};
    my $name = $hash->{NAME};

	my ($passResp,$passErr);

	$data{MATRIX}{"$new"} = $data{MATRIX}{"$old"};
	
	$data{MATRIX}{"$old"} = undef;		#(CoolTux) Wenn ein Hash nicht mehr benötigt wird dann delete
	# Fehler in der nächsten Zeile:
	# delete argument is not a HASH or ARRAY element or slice at lib/FHEM/Devices/Matrix/Matrix.pm line 197.
	# delete $data{MATRIX}{"$old"}

    ($passResp,$passErr) = $hash->{helper}->{passwdobj}->setRename($new,$old);		#(CoolTux) Es empfiehlt sich ab zu fragen ob der Wechsel geklappt hat

	Log3($name, 1, "$name : Matrix::Rename - error while change the password hash after rename - $passErr")
        if ( !defined($passResp)
    	  && defined($passErr) );

	Log3($name, 1, "$name : Matrix::Rename - change password hash after rename successfully")
        if ( defined($passResp)
          && !defined($passErr) );
	
    #my $nhash = $defs{$new};
	return;
}

sub I18N {
	my $value = shift;

	my $def = { 
		'EN' => {
			'require2' => 'requires 2 arguments'
		},
		'DE' => {
			'require2' => 'benötigt 2 Argumente'
		}, 
	};
    my $result = $def->{$language}->{$value};
	return ($result ? $result : $value);
	
}

sub Get {
	my ( $hash, $name, $cmd, @args ) = @_;
	my $value = join(" ", @args);
	#$cmd = '?' if (!$cmd);

	#(CoolTux) Eine endlos Lange elsif Schlange ist nicht zu empfehlen, besser mit switch arbeiten
	#  Im Modulkopf use experimental qw /switch/; verwenden
	given ($cmd) {
		when ('wellknown') {
			return PerformHttpRequest($hash, $cmd, '');
		}

		when ('logintypes') {
			return PerformHttpRequest($hash, $cmd, '');
		}

		when ('sync') {
			$hash->{helper}->{"softfail"} = 0;		#(CoolTux) Bin mir gerade nicht sicher woher das $data kommt
														#  meinst Du das %data aus main? Das ist für User. Wenn Du als Modulentwickler
														#  etwas zwischenspeichern möchtest dann in $hash->{helper} 
			$hash->{helper}->{"hardfail"} = 0;
			return PerformHttpRequest($hash, $cmd, '');
		}

		when ('filter') {
			return qq("get Matrix $cmd" needs a filterId to request);
			return PerformHttpRequest($hash, $cmd, $value);
		}

		default { return "Unknown argument $cmd, choose one of logintypes filter sync wellknown"; }
	}
}

sub Set {
	my ( $hash, $name, $cmd, @args ) = @_;
	my $value = join(" ", @args);
	#$opt = '?' if (!$opt);
	
	#Log3($name, 5, "Set $hash->{NAME}: $name - $cmd - $value");
	#return "set $name needs at least one argument" if (int(@$param) < 3);

	#(CoolTux) Eine endlos Lange elsif Schlange ist nicht zu empfehlen, besser mit switch arbeiten
	#  Im Modulkopf use experimental qw /switch/; verwenden
	
	# if ($cmd eq "msg") {
	# 	return PerformHttpRequest($hash, $cmd, $value);
	# }
	# elsif ($cmd eq "pollFullstate") {
	# 	readingsSingleUpdate($hash, $cmd, $value, 1);                                                        # Readings erzeugen
	# }
	# elsif ($cmd eq "password") {
	# 	my ($erg,$err) = $hash->{helper}->{passwdobj}->setStorePassword($name,$value);
	# 	return undef;
	# }
	# elsif ($cmd eq "filter") {
	# 	return PerformHttpRequest($hash, $cmd, '');
	# }
	# elsif ($cmd eq "question") {
	# 	return PerformHttpRequest($hash, $cmd, $value);
	# }
	# elsif ($cmd eq "questionEnd") {
	# 	return PerformHttpRequest($hash, $cmd, $value);
	# }
	# elsif ($cmd eq "register") {
	# 	return PerformHttpRequest($hash, $cmd, ''); # 2 steps (ToDo: 3 steps empty -> dummy -> registration_token o.a.)
	# }
	# elsif ($cmd eq "login") {
	# 	return PerformHttpRequest($hash, $cmd, '');
	# }
	# elsif ($cmd eq "refresh") {
	# 	return PerformHttpRequest($hash, $cmd, '');
	# }
    # else {		
	# 	return "Unknown argument $cmd, choose one of filter:noArg password question questionEnd pollFullstate:0,1 msg register login:noArg refresh:noArg";
	# }

	given ($cmd) {
		when ('msg') {
			return PerformHttpRequest($hash, $cmd, $value);
		}
		when ('pollFullstate') {
			readingsSingleUpdate($hash, $cmd, $value, 1);                                                        # Readings erzeugen
		}
		when ('password') {
			my ($erg,$err) = $hash->{helper}->{passwdobj}->setStorePassword($name,$value);
			return;
		}
		when ('filter') {
			return PerformHttpRequest($hash, $cmd, '');
		}
		when ('question') {
			return PerformHttpRequest($hash, $cmd, $value);
		}
		when ('questionEnd') {
			return PerformHttpRequest($hash, $cmd, $value);
		}
		when ('register') {
			return PerformHttpRequest($hash, $cmd, ''); # 2 steps (ToDo: 3 steps empty -> dummy -> registration_token o.a.)
		}
		when ('login') {
			return PerformHttpRequest($hash, $cmd, '');
		}
		when ('refresh') {
			return PerformHttpRequest($hash, $cmd, '');
		}

		default {		
			return "Unknown argument $cmd, choose one of filter:noArg password question questionEnd pollFullstate:0,1 msg register login:noArg refresh:noArg";
		}
	}
    
	return;
}


sub Attr {
	my ($cmd,$name,$attr_name,$attr_value) = @_;

	Log3($name, 4, "Attr - $cmd - $name - $attr_name - $attr_value");

	if($cmd eq "set") {
		if ($attr_name eq "matrixQuestion_") {
			my @erg = split(/ /, $attr_value, 2);
			return qq("attr $name $attr_name" ).I18N('require2') if (!$erg[1] || $erg[0] !~ /[0-9]/);
			$_[2] = "matrixQuestion_$erg[0]";
			$_[3] = $erg[1];
		}
		if ($attr_name eq "matrixAnswer_") {
			my @erg = split(/ /, $attr_value, 2);
			return qq(wrong arguments $attr_name") if (!$erg[1] || $erg[0] !~ /[0-9]+/);
			$_[2] = "matrixAnswer_$erg[0]";
			$_[3] = $erg[1];
		}
	}

	return ;
}

sub Get_Message {
	my $name	= shift;
	my $def		= shift;
	my $message	= shift;
	
	Log3($name, 3, "$name - $def - $message");
	my $q = AttrVal($name, "matrixQuestion_$def", "");
	my $a = AttrVal($name, "matrixAnswer_$def", "");
	my @questions = split(':',$q);
	shift @questions if ($def ne '99');
	my @answers = split(':', $a);
	Log3($name, 3, "$name - $q - $a");
	my $pos = 0;
	#my ($question, $answer);
	my $answer;

	# foreach my $question (@questions){
	foreach my $question (@questions){				#(CoolTux) - Loop iterator is not lexical. See page 108 of PBP (Variables::RequireLexicalLoopIterators)perlcritic
												#  This policy asks you to use `my'-style lexical loop iterator variables:

												# foreach my $zed (...) {
												# ...
												# }
		Log3($name, 3, "$name - $question - $answers[$pos]");
		$answer = $answers[$pos] if ($message eq $question);
		if ($answer){
			Log3($name, 3, "$name - $pos - $answer");
			fhem($answer);
			last;
		}
		$pos++;
	}

	return;
}

sub PerformHttpRequest
{
			#(CoolTux) hier solltest Du überlegen das Du die einzelnen Anweisung nach der Bedingung in einzelne Funktionen auslagerst
			# Subroutine "PerformHttpRequest" with high complexity score
			#(Man-Fred) da ich noch nicht wusste wie ähnlich die Ergebnisse sind habe ich erst mal alles zusammen ausgewertet
    my $hash	= shift;
	my $def		= shift;
	my $value	= shift;

	my $now  = gettimeofday();
    my $name = $hash->{NAME};
	my $passwd = "";
	Log3($name, 4, "$name : Matrix::PerformHttpRequest $hash");

	if ($def eq "login" || $def eq "reg2"){
		$passwd = $hash->{helper}->{passwdobj}->getReadPassword($name) ;
	}
	$hash->{helper}->{"msgnumber"} = $hash->{helper}->{"msgnumber"} ? $hash->{helper}->{"msgnumber"} + 1 : 1;
	my $msgnumber = $hash->{helper}->{"msgnumber"};
	my $deviceId = ReadingsVal($name, 'deviceId', undef) ? ', "deviceId":"'.ReadingsVal($name, 'deviceId', undef).'"' : "";
	
    $hash->{helper}->{"busy"} = $hash->{helper}->{"busy"} ? $hash->{helper}->{"busy"} + 1 : 1;      # queue is busy until response is received
	$hash->{helper}->{"sync"} = 0 if (!$hash->{helper}->{"sync"}); 

	$hash->{helper}->{'LASTSEND'} = $now;                                # remember when last sent
	if ($def eq "sync" && $hash->{helper}->{"next_refresh"} < $now && AttrVal($name,'matrixLogin','') eq 'password'){
		$def = "refresh";
		Log3($name, 5, qq($name $hash->{helper}->{"access_token"} sync2refresh - $hash->{helper}->{"next_refresh"} < $now) );
		$hash->{helper}->{"next_refresh"} = $now + 300;
	}
	
    my $param = {
                    timeout    => 10,
                    hash       => $hash,                                      # Muss gesetzt werden, damit die Callback funktion wieder $hash hat
                    def        => $def,                                       # sichern für eventuelle Wiederholung
					value      => $value,                                     # sichern für eventuelle Wiederholung
                    method     => "POST",                                     # standard, sonst überschreiben
                    header     => "User-Agent: HttpUtils/2.2.3\r\nAccept: application/json",  # Den Header gemäß abzufragender Daten setzen
                    callback   => \&ParseHttpResponse,                        # Diese Funktion soll das Ergebnis dieser HTTP Anfrage bearbeiten
					msgnumber  => $msgnumber                                  # lfd. Nummer Request
                };
	
	if ($def eq "logintypes"){
      $param->{'url'} =  $hash->{server}."/_matrix/client/r0/login";
	  $param->{'method'} = 'GET';
	}
	if ($def eq "register"){
      $param->{'url'} =  $hash->{server}."/_matrix/client/v3/register";
      $param->{'data'} = '{"type":"m.login.password", "identifier":{ "type":"m.id.user", "user":"'.$hash->{user}.'" }, "password":"'.$passwd.'"}';
	}
	if ($def eq "reg1"){
      $param->{'url'} =  $hash->{server}."/_matrix/client/v3/register";
      $param->{'data'} = '{"type":"m.login.password", "identifier":{ "type":"m.id.user", "user":"'.$hash->{user}.'" }, "password":"'.$passwd.'"}';
	}
	if ($def eq"reg2"){
      $param->{'url'} =  $hash->{server}."/_matrix/client/v3/register";
      $param->{'data'} = '{"username":"'.$hash->{user}.'", "password":"'.$passwd.'", "auth": {"session":"'.$hash->{helper}->{"session"}.'","type":"m.login.dummy"}}';
	}
	if ($def eq "login"){
	  if (AttrVal($name,'matrixLogin','') eq 'token'){
		  $param->{'url'} =  $hash->{server}."/_matrix/client/v3/login";
          $param->{'data'} = qq({"type":"m.login.token", "token":"$passwd", "user": "$hash->{user}", "txn_id": "z4567gerww", "session":"1234"});
		  #$param->{'method'} = 'GET';
	  } else {
		  $param->{'url'} =  $hash->{server}."/_matrix/client/v3/login";
          $param->{'data'} = '{"type":"m.login.password", "refresh_token": true, "identifier":{ "type":"m.id.user", "user":"'.$hash->{user}.'" }, "password":"'.$passwd.'"'.$deviceId.'}';
	  }
	}
	if ($def eq "login2"){
      $param->{'url'} =  $hash->{server}."/_matrix/client/v3/login";
	  if (AttrVal($name,'matrixLogin','') eq 'token'){
          $param->{'data'} = qq({"type":"m.login.token", "token":"$passwd", "user": "\@$hash->{user}:matrix.org", "txn_id": "z4567gerww"});
          #$param->{'data'} = qq({"type":"m.login.token", "token":"$passwd"});
	  }
	}
	if ($def eq "refresh"){              
      $param->{'url'} =  $hash->{server}.'/_matrix/client/v1/refresh'; 
      $param->{'data'} = '{"refresh_token": "'.$hash->{helper}->{"refresh_token"}.'"}';
	  Log3($name, 5, qq($name $hash->{helper}->{"access_token"} refreshBeg $param->{'msgnumber'}: $hash->{helper}->{"next_refresh"} > $now) );
	}
	if ($def eq "wellknown"){
      $param->{'url'} =  $hash->{server}."/.well-known/matrix/client";
 	}
	if ($def eq "msg"){              
      $param->{'url'} =  $hash->{server}.'/_matrix/client/r0/rooms/'.AttrVal($name, 'matrixMessage', '!!').'/send/m.room.message?access_token='.$hash->{helper}->{"access_token"};
      $param->{'data'} = '{"msgtype":"m.text", "body":"'.$value.'"}';
	}
	if ($def eq "question"){ 
	  $hash->{helper}->{"question"}=$value;
      $value = AttrVal($name, "matrixQuestion_$value",""); #  if ($value =~ /[0-9]/);
	  my @question = split(':',$value);
	  my $size = @question;
	  my $answer;
	  my $q = shift @question;
	  $value =~ s/:/<br>/g;
	  # min. question and one answer
	  if (int(@question) >= 2){
		  $param->{'url'} =  $hash->{server}.'/_matrix/client/v3/rooms/'.AttrVal($name, 'matrixMessage', '!!').
			'/send/m.poll.start?access_token='.$hash->{helper}->{"access_token"};
		  $param->{'data'} = '{"org.matrix.msc3381.poll.start": {"max_selections": 1,'.
		  '"question": {"org.matrix.msc1767.text": "'.$q.'"},'.
		  '"kind": "org.matrix.msc3381.poll.undisclosed","answers": [';
		  my $comma = '';
		  foreach $answer (@question){
			  $param->{'data'} .= qq($comma {"id": "$answer", "org.matrix.msc1767.text": "$answer"});
			  $comma = ',';
		  }
		  $param->{'data'} .= qq(],"org.matrix.msc1767.text": "$value"}});
	  } else {
		  Log3($name, 5, "question: $value $size $question[0]");
		  return;
	  }
	}
	if ($def eq "questionEnd"){   
	  $value = ReadingsVal($name, "questionId", "") if (!$value);
      $param->{'url'} =  $hash->{server}.'/_matrix/client/v3/rooms/'.AttrVal($name, 'matrixMessage', '!!').'/send/m.poll.end?access_token='.$hash->{helper}->{"access_token"};
      $param->{'data'} = '{"m.relates_to": {"rel_type": "m.reference","eventId": "'.$value.'"},"org.matrix.msc3381.poll.end": {},'.
                '"org.matrix.msc1767.text": "Antort '.ReadingsVal($name, "answer", "").' erhalten von '.ReadingsVal($name, "sender", "").'"}';
	}
	if ($def eq "sync"){  
		my $since = ReadingsVal($name, "since", undef) ? '&since='.ReadingsVal($name, "since", undef) : "";
		my $full_state = ReadingsVal($name, "pollFullstate",undef);
		if ($full_state){
			$full_state = "&full_state=true";
			readingsSingleUpdate($hash, "pollFullstate", 0, 1);
		} else {
			$full_state = "";
		}
		$param->{'url'} =  $hash->{server}.'/_matrix/client/r0/sync?access_token='.$hash->{helper}->{"access_token"}.$since.$full_state.'&timeout=50000&filter='.ReadingsVal($name, 'filterId',0);
		$param->{'method'} = 'GET';
		$param->{'timeout'} = 60;
		$hash->{helper}->{"sync"}++;
		Log3($name, 5, qq($name $hash->{helper}->{"access_token"} syncBeg $param->{'msgnumber'}: $hash->{helper}->{"next_refresh"} > $now) );
	}
	if ($def eq "filter"){
      if ($value){ # get
		  $param->{'url'} =  $hash->{server}.'/_matrix/client/v3/user/'.ReadingsVal($name, "userId",0).'/filter/'.$value.'?access_token='.$hash->{helper}->{"access_token"};
		  $param->{'method'} = 'GET';
	  } else {	  
		  $param->{'url'} =  $hash->{server}.'/_matrix/client/v3/user/'.ReadingsVal($name, "userId",0).'/filter?access_token='.$hash->{helper}->{"access_token"};
		  $param->{'data'} = '{';
		  $param->{'data'} .= '"event_fields": ["type","content","sender"],';
		  $param->{'data'} .= '"event_format": "client", ';
		  $param->{'data'} .= '"presence": { "senders": [ "@xx:example.com"]}'; # no presence
		  #$param->{'data'} .= '"room": { "ephemeral": {"rooms": ["'.AttrVal($name, 'matrixRoom', '!!').'"],"types": ["m.receipt"]}, "state": {"types": ["m.room.*"]},"timeline": {"types": ["m.room.message"] } }';
		  $param->{'data'} .= '}';
	  }
	}

    my $test = "$param->{url}, "
        . ( $param->{data}   ? "\r\ndata: $param->{data}, "   : "" )
        . ( $param->{header} ? "\r\nheader: $param->{header}" : "" );
	#readingsSingleUpdate($hash, "fullRequest", $test, 1);                                                        # Readings erzeugen
	$test = "$name: Matrix sends with timeout $param->{timeout} to $test";
    Log3($name, 5, $test);
          
	Log3($name, 3, qq($name $param->{'msgnumber'} $def Request Busy/Sync $hash->{helper}->{"busy"} / $hash->{helper}->{"sync"}) );
    HttpUtils_NonblockingGet($param);   #  Starten der HTTP Abfrage. Es gibt keinen Return-Code. 

	return; 
}

sub ParseHttpResponse
{

			#(CoolTux) hier solltest Du überlegen das Du die einzelnen Anweisung nach der Bedingung in einzelne Funktionen auslagerst
			# Subroutine "PerformHttpRequest" with high complexity score
			#(Man-Fred) da ich noch nicht wusste wie ähnlich die Ergebnisse sind habe ich erst mal alles zusammen ausgewertet

    my $param	= shift;
	my $err		= shift;
	my $data	= shift;


    my $hash = $param->{hash};
	my $def = $param->{def};
	my $value = $param->{value};
    my $name = $hash->{NAME};
	my $now  = gettimeofday();
	my $nextRequest = "";

	Log3($name, 3, qq($name $param->{'msgnumber'} $def Result $param->{code}) );
    readingsBeginUpdate($hash);
	###readingsBulkUpdate($hash, "httpHeader", $param->{httpheader});
	readingsBulkUpdate($hash, "httpStatus", $param->{code});
	$hash->{STATE} = $def.' - '.$param->{code};
    if($err ne "") {                                                         # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
        Log3($name, 2, "error while requesting ".$param->{url}." - $err");   # Eintrag fürs Log
        readingsBulkUpdate($hash, "responseError", $err);                    # Reading erzeugen
		$hash->{helper}->{"softfail"} = 3;
		$hash->{helper}->{"hardfail"}++;
    }
    elsif($data ne "") {                                                     # wenn die Abfrage erfolgreich war ($data enthält die Ergebnisdaten des HTTP Aufrufes)
		Log3($name, 4, $def." returned: $data");              # Eintrag fürs Log
		my $decoded = eval { JSON::decode_json($data) };
		Log3($name, 2, "$name: json error: $@ in data") if( $@ );
        if ($param->{code} == 200){
			$hash->{helper}->{"softfail"} = 0;
			$hash->{helper}->{"hardfail"} = 0;
		} else {
			$hash->{helper}->{"softfail"}++;
			$hash->{helper}->{"hardfail"}++ if ($hash->{helper}->{"softfail"} > 3);
			readingsBulkUpdate($hash, "responseError", qq(S$data{MATRIX}{$name}{'softfail'}: $data) );        
    		Log3($name, 5, qq($name $hash->{helper}->{"access_token"} ${def}End $param->{'msgnumber'}: $hash->{helper}->{"next_refresh"} > $now) );
		}
        # readingsBulkUpdate($hash, "fullResponse", $data); 
		
		# default next request
		$nextRequest = "sync" ;
        # An dieser Stelle die Antwort parsen / verarbeiten mit $data
				
		# "errcode":"M_UNKNOWN_TOKEN: login or refresh
		my $errcode = $decoded->{'errcode'} ? $decoded->{'errcode'} : "";
		if ($errcode eq "M_UNKNOWN_TOKEN"){
			$hash->{helper}->{"repeat"} = $param if ($def ne "sync");
			if ($decoded->{'error'} eq "Access token has expired"){
				if ($decoded->{'soft_logout'} eq "true"){
					$nextRequest = 'refresh';
				}else{
					$nextRequest = 'login';
				}
			} elsif ($decoded->{'error'} eq "refresh token does not exist"){
				$nextRequest = 'login';
			}
		}
        
        if ($def eq "register"){
			$hash->{helper}->{"session"} = $decoded->{'session'};
			$nextRequest = "";#"reg2";
		}
		$hash->{helper}->{"session"} = $decoded->{'session'} if ($decoded->{'session'});
		readingsBulkUpdate($hash, "session", $decoded->{'session'}) if ($decoded->{'session'});

		if ($def eq  "reg2" || $def eq  "login" || $def eq "refresh") {
			readingsBulkUpdate($hash, "lastRegister", $param->{code}) if $def eq  "reg2";
			readingsBulkUpdate($hash, "lastLogin",  $param->{code}) if $def eq  "login";
			readingsBulkUpdate($hash, "lastRefresh", $param->{code}) if $def eq  "refresh";
			if ($param->{code} == 200){
				readingsBulkUpdate($hash, "userId", $decoded->{'user_id'}) if ($decoded->{'user_id'});
				readingsBulkUpdate($hash, "homeServer", $decoded->{'homeServer'}) if ($decoded->{'homeServer'});
				readingsBulkUpdate($hash, "deviceId", $decoded->{'device_id'}) if ($decoded->{'device_id'});
				
				$hash->{helper}->{"expires"} = $decoded->{'expires_in_ms'} if ($decoded->{'expires_in_ms'});
				$hash->{helper}->{"refresh_token"} = $decoded->{'refresh_token'} if ($decoded->{'refresh_token'}); 
				$hash->{helper}->{"access_token"} =  $decoded->{'access_token'} if ($decoded->{'access_token'});
				$hash->{helper}->{"next_refresh"} = $now + $hash->{helper}->{"expires"}/1000 - 60; # refresh one minute before end
			}
    		Log3($name, 5, qq($name $hash->{helper}->{"access_token"} refreshEnd $param->{'msgnumber'}: $hash->{helper}->{"next_refresh"} > $now) );
		}
        if ($def eq "wellknown"){
			# https://spec.matrix.org/unstable/client-server-api/
		}
        if ($param->{code} == 200 && $def eq "sync"){
    		Log3($name, 5, qq($name $hash->{helper}->{"access_token"} syncEnd $param->{'msgnumber'}: $hash->{helper}->{"next_refresh"} > $now) );
			readingsBulkUpdate($hash, "since", $decoded->{'next_batch'}) if ($decoded->{'next_batch'});
			# roomlist
			my $list = $decoded->{'rooms'}->{'join'};
			#my @roomlist = ();
			my $pos = 0;
			foreach my $id ( keys $list->%* ) {
				if (ref $list->{$id} eq ref {}) {
					my $member = "";
					#my $room = $list->{$id};
					$pos = $pos + 1;
					# matrixRoom ?
					readingsBulkUpdate($hash, "room$pos.id", $id); 
					#foreach my $id ( $decoded->{'rooms'}->{'join'}->{AttrVal($name, 'matrixRoom', '!!')}->{'timeline'}->{'events'}->@* ) {
					foreach my $ev ( $list->{$id}->{'state'}->{'events'}->@* ) {
						readingsBulkUpdate($hash, "room$pos.topic", $ev->{'content'}->{'topic'}) if ($ev->{'type'} eq 'm.room.topic'); 
						readingsBulkUpdate($hash, "room$pos.name", $ev->{'content'}->{'name'}) if ($ev->{'type'} eq 'm.room.name'); 
						$member .= "$ev->{'sender'} " if ($ev->{'type'} eq 'm.room.member'); 
					}
					readingsBulkUpdate($hash, "room$pos.member", $member); 
					foreach my $tl ( $list->{$id}->{'timeline'}->{'events'}->@* ) {
						readingsBulkUpdate($hash, "room$pos.topic", $tl->{'content'}->{'topic'}) if ($tl->{'type'} eq 'm.room.topic'); 
						readingsBulkUpdate($hash, "room$pos.name", $tl->{'content'}->{'name'}) if ($tl->{'type'} eq 'm.room.name'); 
						if ($tl->{'type'} eq 'm.room.message' && $tl->{'content'}->{'msgtype'} eq 'm.text'){
							my $sender = $tl->{'sender'};
							my $message = $tl->{'content'}->{'body'};
							if (AttrVal($name, 'matrixSender', '') =~ $sender){
								readingsBulkUpdate($hash, "message", $message); 
								readingsBulkUpdate($hash, "sender", $sender); 
								# command
								Get_Message($name, '99', $message);
							}
							#else {
							#	readingsBulkUpdate($hash, "message", 'ignoriert, nicht '.AttrVal($name, 'matrixSender', '')); 
							#	readingsBulkUpdate($hash, "sender", $sender); 
							#}
						} elsif ($tl->{'type'} eq "org.matrix.msc3381.poll.response"){
							my $sender = $tl->{'sender'};
							my $message = $tl->{'content'}->{'org.matrix.msc3381.poll.response'}->{'answers'}[0];
							if ($tl->{'content'}->{'m.relates_to'}){
								if ($tl->{'content'}->{'m.relates_to'}->{'rel_type'} eq 'm.reference'){
									readingsBulkUpdate($hash, "questionId", $tl->{'content'}->{'m.relates_to'}->{'event_id'})
								}
							}
							if (AttrVal($name, 'matrixSender', '') =~ $sender){
								readingsBulkUpdate($hash, "message", $message); 
								readingsBulkUpdate($hash, "sender", $sender); 
								$nextRequest = "questionEnd" ;
								# command
								Get_Message($name, $hash->{helper}->{"question"}, $message);
							}
						}
					}
					#push(@roomlist,"$id: ";
				}
			}
		}
        if ($def eq "logintypes"){
			my $types = '';
			foreach my $flow ( $decoded->{'flows'}->@* ) {
				if ($flow->{'type'} =~ /m\.login\.(.*)/) {
					#$types .= "$flow->{'type'} ";
					$types .= "$1 ";# if ($flow->{'type'} );
				}
			}
			readingsBulkUpdate($hash, "logintypes", $types);
		}
        if ($def eq "filter"){
			readingsBulkUpdate($hash, "filterId", $decoded->{'filter_id'}) if ($decoded->{'filter_id'});
		}
        if ($def eq "msg" ){
			readingsBulkUpdate($hash, "eventId", $decoded->{'event_id'}) if ($decoded->{'event_id'});
			#m.relates_to
		}
        if ($def eq "question"){
			readingsBulkUpdate($hash, "questionId", $decoded->{'event_id'}) if ($decoded->{'event_id'});
			#m.relates_to
		}
        if ($def eq "questionEnd"){
			readingsBulkUpdate($hash, "eventId", $decoded->{'event_id'}) if ($decoded->{'event_id'});
			readingsBulkUpdate($hash, "questionId", "") if ($decoded->{'event_id'});
			#m.relates_to
		}
	}

    readingsEndUpdate($hash, 1);
    $hash->{helper}->{"busy"}--; # = $hash->{helper}->{"busy"} - 1;      # queue is busy until response is received
	$hash->{helper}->{"sync"}-- if ($def eq "sync");                   # possible next sync
	$nextRequest = "" if ($nextRequest eq "sync" && $hash->{helper}->{"sync"} > 0); # only one sync at a time!
	
	# PerformHttpRequest or InternalTimer if FAIL >= 3
	Log3($name, 4, "$name : Matrix::ParseHttpResponse $hash");
	if (AttrVal($name,'matrixPoll',0) == 1){
		if ($nextRequest ne "" && $hash->{helper}->{"softfail"} < 3) {
			if ($nextRequest eq "sync" && $hash->{helper}->{"repeat"}){
				$def = $hash->{helper}->{"repeat"}->{"def"};
				$value = $hash->{helper}->{"repeat"}->{"value"};
				$hash->{helper}->{"repeat"} = undef;
				PerformHttpRequest($hash, $def, $value);
			} else {
				PerformHttpRequest($hash, $nextRequest, '');
			}
		} else {
			my $pauseLogin;
			if ($hash->{helper}->{"hardfail"} >= 3){
				$pauseLogin = 300;
			} elsif ($hash->{helper}->{"softfail"} >= 3){
				$pauseLogin = 30;
			} elsif ($hash->{helper}->{"softfail"} > 0){
				$pauseLogin = 10;
			} else {
				$pauseLogin = 0;
			}
			if ($pauseLogin > 0){
				my $timeToStart = gettimeofday() + $pauseLogin;
				RemoveInternalTimer($hash->{myTimer}) if($hash->{myTimer});
				$hash->{myTimer} = { hash=>$hash };
				InternalTimer($timeToStart, \&FHEM::Devices::Matrix::Login, $hash->{myTimer});
			} else {
				Login($hash);
			}
		}
	}
    # Damit ist die Abfrage zuende.

	return;
}


1;		#(CoolTux) ein Modul endet immer mit 1;

__END__		#(CoolTux) Markiert im File das Ende des Programms. Danach darf beliebiger Text stehen. Dieser wird vom Perlinterpreter nicht berücksichtigt.