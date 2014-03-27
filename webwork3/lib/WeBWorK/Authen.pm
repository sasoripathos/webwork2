################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2007 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/lib/WeBWorK/Authen.pm,v 1.63 2012/06/06 22:03:15 wheeler Exp $
# 
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::Authen;

use strict;
use warnings;
use Dancer;
use Data::Dumper;
use WeBWorK::Debug;
use WeBWorK::GeneralUtils qw/writeCourseLog runtime_use/;
use Scalar::Util qw(weaken);
use Carp qw/croak/;

#use vars qw($GENERIC_ERROR_MESSAGE);
our $GENERIC_ERROR_MESSAGE = "";  # define in new

################################################################################
# Public API
################################################################################

=head1 FACTORY

=over

=item class($ce, $type)

This subroutine consults the given WeBWorK::CourseEnvironment object to
determine which WeBWorK::Authen subclass should be used. $type can be any key
given in the %authen hash in the course environment. If the type is not found in
the %authen hash, an exception is thrown.

=cut

sub class {
	my ($ce, $type) = @_;
	
	if (exists $ce->{authen}{$type}) {
		if (ref $ce->{authen}{$type} eq "ARRAY") {
			my $authen_type = shift @{$ce ->{authen}{$type}};
			#debug("ref of authen_type = |" . ref($authen_type) . "|");
			if (ref ($authen_type) eq "HASH") {
				if (exists $authen_type->{$ce->{dbLayoutName}}) {
					return $authen_type->{$ce->{dbLayoutName}};
				} elsif (exists $authen_type->{"*"}) {
					return $authen_type->{"*"};
				} else {
					die "authentication type '$type' in the course environment has no entry for db layout '", $ce->{dbLayoutName}, "' and no default entry (*)";
				}
			} else {
					return $authen_type;
			}
		} elsif (ref $ce->{authen}{$type} eq "HASH") {
			if (exists $ce->{authen}{$type}{$ce->{dbLayoutName}}) {
				return $ce->{authen}{$type}{$ce->{dbLayoutName}};
			} elsif (exists $ce->{authen}{$type}{"*"}) {
				return $ce->{authen}{$type}{"*"};
			} else {
				die "authentication type '$type' in the course environment has no entry for db layout '", $ce->{dbLayoutName}, "' and no default entry (*)";
			}
		} else {
			return $ce->{authen}{$type};
		}
	} else {
		die "authentication type '$type' not found in course environment";
	}
}

sub call_next_authen_method {
	my ($self,$ce) = shift;

	my $user_authen_module = WeBWorK::Authen::class($ce, "user_module");
	#debug("user_authen_module = |$user_authen_module|");	
	if (!defined($user_authen_module) or ($user_authen_module eq "")) {
		$self->{error} = "No authentication method found for your request.  "
			. "If this recurs, please speak with your instructor.";
		$self->{log_error} .= "None of the specified authentication modules could handle the request.";
		return(0);
	} else {

		# not sure what to do here without a Request Object		

		#runtime_use $user_authen_module;
		# my $authen = $user_authen_module->new($r);
		#debug("Using user_authen_module $user_authen_module: $authen\n");
	 	# $r->authen($authen);

		return;
	}
}


=back

=cut

=head1 CONSTRUCTOR

=over

=item new($r)

Instantiates a new WeBWorK::Authen object for the given WeBWorK::CourseEnvironment ($ce).

=cut

sub new {
	my ($invocant,$ce) = @_;
	my $class = ref($invocant) || $invocant;
	my $self = {
	 	ce => $ce,
	 	db => new WeBWorK::DB($ce->{dbLayout}),
	 	params => {}
	};
	# weaken $self -> {r};
	#initialize
	# $GENERIC_ERROR_MESSAGE = $r->maketext("Invalid user ID or password.");
	bless $self, $class;
	return $self;
}


#  0 == required data was present, but authentication failed
# -1 == required data was not present (i.e. password missing)
sub authenticate {
	my $self = shift;
	# my $r = $self->{r};
	
	my $user_id = $self->{params}->{user};
	my $password = $self->{params}->{password};
	
	if (defined $password) {
		return $self->checkPassword($user_id, $password);
	} else {
		return -1;
	}
}

sub set_params {
	my ($self,$params) = @_;
	$self->{params} = $params;
}

################################################################################
# Password management
################################################################################

sub checkPassword {
	my ($self, $userID, $possibleClearPassword) = @_;

	debug $userID;
	debug $possibleClearPassword;

	my $Password = $self->{db}->getPassword($userID); # checked
	if (defined $Password) {
		# check against WW password database
		my $possibleCryptPassword = crypt $possibleClearPassword, $Password->password;
		if ($possibleCryptPassword eq $Password->password) {
			$self->write_log_entry("AUTH WWDB: password accepted");
			return 1;
		} else {
			if ($self->can("site_checkPassword")) {
				$self->write_log_entry("AUTH WWDB: password rejected, deferring to site_checkPassword");
				return $self->site_checkPassword($userID, $possibleClearPassword);
			} else {
				$self->write_log_entry("AUTH WWDB: password rejected");
				return 0;
			}
		}
	} else {
		$self->write_log_entry("AUTH WWDB: user has no password record");
		return 0;
	}
}

sub  request_has_data_for_this_verification_module {
	#debug("Authen::request_has_data_for_this_verification_module will return a 1");
	return(1);
}


sub verify {
	debug("BEGIN VERIFY");
	my $self = shift;

	if (! ($self-> request_has_data_for_this_verification_module)) {
		return ( $self -> call_next_authen_method());
	}

	my $result = $self->do_verify;
	my $error = $self->{error};
	my $log_error = $self->{log_error};
	
	$self->{was_verified} = $result ? 1 : 0;
	
	if ($self->can("site_fixup")) {
		$self->site_fixup;
	}
	
	if ($result) {
		$self->write_log_entry("LOGIN OK") if $self->{initial_login};
		#$self->maybe_send_cookie;
		#$self->set_params;
	} else {
		if (defined $log_error) {
			$self->write_log_entry("LOGIN FAILED $log_error");
		}
		if (defined($error) and $error=~/\S/) { # if error message has a least one non-space character. 

			#if (defined($r->param("user")) or defined($r->param("user_id"))) {
			if(defined($self->{params}->{user_id})){
				$error = "Your authentication failed.  Please try again."
					. "  Please speak with your instructor if you need help.";
			}

		}

		$self->maybe_kill_cookie;
		if (defined($error) and $error=~/\S/) { # if error message has a least one non-space character. 
			return $error;
			# MP2 ? $r->notes->set(authen_error => $error) : $r->notes("authen_error" => $error);
		}
	}

	debug Dumper($self->{params});

	for my $key (qw/user_id session_key user key error log_error/){
		debug $self->{$key};
	}

	
	debug("END VERIFY");
	return $result;
}

=item was_verified()

Returns true if verify() returned true the last time it was called.

=cut

sub was_verified {
	my ($self) = @_;
	return 1 if exists $self->{was_verified} and $self->{was_verified};
	return 0;
}

=item forget_verification()

Future calls to was_verified() will return false, until verify() is called again and succeeds.

=cut

sub forget_verification {
	my $self = shift;
	$self->{was_verified} = 0;	
}

=back

=cut

################################################################################
# Helper functions (called by verify)
################################################################################

sub do_verify {
	my $self = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};
	
	return 0 unless $db;
	
	return 0 unless $self->get_credentials;


#	return 0 unless $self->check_user;
	
	my $practiceUserPrefix = $ce->{practiceUserPrefix};
	if (defined($self->{login_type}) && $self->{login_type} eq "guest"){
		return $self->verify_practice_user;
	} else {
		return $self->verify_normal_user;
	}
}

## pass all of the parameters as a reference to a has


sub get_credentials {
	my $self = shift;
	my $ce = $self->{ce};
	my $db = $self->{db};

	
	# allow guest login: if the "Guest Login" button was clicked, we find an unused
	# practice user and create a session for it.
	if ($self->{params}->{login_practice_user}) {
		my $practiceUserPrefix = $ce->{practiceUserPrefix};
		# DBFIX search should happen in database
		my @guestUserIDs = grep m/^$practiceUserPrefix/, $db->listUsers;
		my @GuestUsers = $db->getUsers(@guestUserIDs);
		my @allowedGuestUsers = grep { $ce->status_abbrev_has_behavior($_->status, "allow_course_access") } @GuestUsers;
		my @allowedGuestUserIDs = map { $_->user_id } @allowedGuestUsers;
		
		foreach my $userID (@allowedGuestUserIDs) { 
			if (not $self->unexpired_session_exists($userID)) {
				my $newKey = $self->create_session($userID);
				$self->{initial_login} = 1;
				$self->{user_id} = $userID;
				$self->{session_key} = $newKey;
				$self->{login_type} = "guest";
				$self->{credential_source} = "none";
				debug("guest user '", $userID. "' key '", $newKey. "'");
				return 1;
			}
		}
		
		$self->{log_error} = "no guest logins are available";
		$self->{error} = "No guest logins are available. Please try again in a few minutes.";
		return 0;
	}
	
	# my ($cookieUser, $cookieKey, $cookieTimeStamp) = $self->fetchCookie;

	# if (defined $cookieUser and defined $r->param("user") ) {
	# 	if ($cookieUser ne $r->param("user")) {
	# 		croak ("cookieUser = $cookieUser and paramUser = ". $r->param("user") . " are different.");
	# 	}
# I don't understand this next segment.
# If both key and $cookieKey exist then why not just ignore the cookieKey?

# 		if (defined $cookieKey and defined $r->param("key")) {
# 			$self -> {user_id} = $cookieUser;
# 			$self -> {password} = $r->param("passwd");
# 			$self -> {login_type} = "normal";
# 			$self -> {credential_source} = "params_and_cookie";
# 			$self -> {session_key} = $cookieKey;
# 			$self -> {cookie_timestamp} = $cookieTimeStamp;
# 			if ($cookieKey ne $r->param("key")) {
# 				warn ("cookieKey = $cookieKey and param key = " . $r -> param("key") . " are different, perhaps"
# 					 ." because you opened several windows for the same site and then backed up from a newer one to an older one."
# 					 ."  Avoid doing so.");
# 			$self -> {credential_source} = "conflicting_params_and_cookie";
# 			}
# 			debug("params and cookie user '", $self->{user_id}, "' credential_source = '", $self->{credential_source},
# 				"' params and cookie session key = '", $self->{session_key}, "' cookie_timestamp '", $self->{cookieTimeStamp}, "'");
# 			return 1;
# 		} els

# Use session key for verification
# else   use cookieKey for verification
# else    use cookie user name but use password provided by request.

		if (defined $self->{params}->{key}) {
			$self->{user_id} = $self->{params}->{user};
			$self->{session_key} = $self->{params}->{key};
			$self->{password} = $self->{params}->{password};
			$self->{login_type} = "normal";
			$self->{credential_source} = "params";
			debug("params user '", $self->{user_id}, "' password '", $self->{password}, "' key '", $self->{session_key}, "'");
			return 1;
		} 
		## don't deal with cookie keys right now.

		# elsif (defined $cookieKey) {
		# 	$self->{user_id} = $cookieUser;
		# 	$self->{session_key} = $cookieKey;
		# 	$self->{cookie_timestamp} = $cookieTimeStamp;
		# 	$self->{login_type} = "normal";
		# 	$self->{credential_source} = "cookie";
		# 	debug("cookie user '", $self->{user_id}, "' key '", $self->{session_key}, "' cookie_timestamp '", $self->{cookieTimeStamp}, "'");
		# 	return 1;
		# } else {
		# 	$self -> {user_id} = $cookieUser;
		# 	$self -> {session_key} = $cookieKey; # will be undefined
		# 	$self -> {password} = $r->param("passwd");
		# 	$self -> {cookie_timestamp} = $cookieTimeStamp;
		# 	$self -> {login_type} = "normal";
		# 	$self -> {credential_source} = "params_and_cookie";
		# 	debug("params and cookie user '", $self->{user_id}, "' params and cookie session key = '",
		# 		 $self->{session_key}, "' cookie_timestamp '", $self->{cookieTimeStamp}, "'");
		# 	return 1;
		# }	
	#}
	# at least the user ID is available in request parameters
	if (defined $self->{params}->{user}) {
		$self->{user_id} = $self->{params}->{user};
		$self->{session_key} = $self->{params}->{key};
		$self->{password} = $self->{params}->{password};
		$self->{login_type} = "normal";
		$self->{credential_source} = "params";
		debug Dumper($self->{params});
		debug("params user '", $self->{user_id}, "' password '", $self->{password}, "' key '", $self->{session_key}, "'");
		return 1;
	}
	
	#  if (defined $cookieUser) {
	# 	$self->{user_id} = $cookieUser;
	# 	$self->{session_key} = $cookieKey;
	# 	$self->{cookie_timestamp} = $cookieTimeStamp;
	# 	$self->{login_type} = "normal";
	# 	$self->{credential_source} = "cookie";
	# 	debug("cookie user '", $self->{user_id}, "' key '", $self->{session_key}, "' cookie_timestamp '", $self->{cookieTimeStamp}, "'");
	# 	return 1;
	# }



}

# sub check_user {
# 	my $self = shift;
# 	my $r = $self->{r};
# 	my $ce = $r->{ce};
# 	my $db = $r->{db};
# 	my $authz = $r->authz;
	
# 	my $user_id = $self->{user_id};
	
# 	if (defined $user_id and $user_id eq "") {
# 		$self->{log_error} = "no user id specified";
# 		$self->{error} .= $r->maketext("You must specify a user ID.");
# 		return 0;
# 	}
	
# 	my $User = $db->getUser($user_id);
	
# 	unless ($User) {
# 		$self->{log_error} = "user unknown";
# 		$self->{error} = $GENERIC_ERROR_MESSAGE;
# 		return 0;
# 	}
	
# 	# FIXME "fix invalid status values" used to be here, but it needs to move to $db->getUser
	
# 	unless ($ce->status_abbrev_has_behavior($User->status, "allow_course_access")) {
# 		$self->{log_error} = "user not allowed course access";
# 		$self->{error} = $GENERIC_ERROR_MESSAGE;
# 		return 0;
# 	}
	
# 	unless ($authz->hasPermissions($user_id, "login")) {
# 		$self->{log_error} = "user not permitted to login";
# 		$self->{error} = $GENERIC_ERROR_MESSAGE;
# 		return 0;
# 	}
	
# 	return 1;
# }

sub verify_practice_user {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	
	my $user_id = $self->{user_id};
	my $session_key = $self->{session_key};
	
	for my $key (qw/user_id session_key/){
		debug $self->{$key};
	}

	my ($sessionExists, $keyMatches, $timestampValid) = $self->check_session($user_id, $session_key, 1);
	debug("sessionExists='", $sessionExists, "' keyMatches='", $keyMatches, "' timestampValid='", $timestampValid, "'");
	
	if ($sessionExists) {
		if ($keyMatches) {
			if ($timestampValid) {
				return 1;
			} else {
				$self->{session_key} = $self->create_session($user_id);
				$self->{initial_login} = 1;
				return 1;
			}
		} else {
			if ($timestampValid) {
				my $debugPracticeUser = $ce->{debugPracticeUser};
				if (defined $debugPracticeUser and $user_id eq $debugPracticeUser) {
					$self->{session_key} = $self->create_session($user_id);
					$self->{initial_login} = 1;
					return 1;
				} else {
					$self->{log_error} = "guest account in use";
					$self->{error} = "That guest account is in use.";
					return 0;
				}
			} else {
				$self->{session_key} = $self->create_session($user_id);
				$self->{initial_login} = 1;
				return 1;
			}
		}
	} else {
		$self->{session_key} = $self->create_session($user_id);
		$self->{initial_login} = 1;
		return 1;
	}
}

sub verify_normal_user {
	my $self = shift;
	#my $r = $self->{r};
	
	my $user_id = $self->{user_id};
	my $session_key = $self->{session_key};

	for my $key (qw/user user_id session_key key/){
		debug "$key: " . ($self->{$key} || "")
	}


	
	my ($sessionExists, $keyMatches, $timestampValid) = $self->check_session($user_id, $session_key, 1);
	debug("sessionExists='", $sessionExists, "' keyMatches='", $keyMatches, "' timestampValid='", $timestampValid, "'");
	
	if ($sessionExists and $keyMatches and $timestampValid) {
		return 1;
	} else {
		my $auth_result = $self->authenticate;
		
		if ($auth_result > 0) {
			$self->{session_key} = $self->create_session($user_id);
			$self->{initial_login} = 1;
			return 1;
		} elsif ($auth_result == 0) {
			$self->{log_error} = "authentication failed";
			$self->{error} = $GENERIC_ERROR_MESSAGE;
			return 0;
		} else { # ($auth_result < 0) => required data was not present
			if ($keyMatches and not $timestampValid) {
				$self->{log_error} = "inactivity timeout";
				$self->{error} .= "Your session has timed out due to inactivity. Please log in again.";
			}
			return 0;
		}
	}
}


sub maybe_send_cookie {
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r -> {ce};
	
	my ($cookie_user, $cookie_key, $cookie_timestamp) = $self->fetchCookie;
	
	# we send a cookie if any of these conditions are met:
	
	# (a) a cookie was used for authentication
	my $used_cookie = ($self->{credential_source} eq "cookie");
	
	# (b) a cookie was sent but not used for authentication, and the
	#     credentials used for authentication were the same as those in
	#     the cookie
	my $unused_valid_cookie = ($self->{credential_source} ne "cookie"
		and defined $cookie_user and $self->{user_id} eq $cookie_user
		and defined $cookie_key and $self->{session_key} eq $cookie_key);
	
	# (c) the user asked to have a cookie sent and is not a guest user.
	my $user_requests_cookie = ($self->{login_type} ne "guest"
		and $r->param("send_cookie"));

	# (d) session management is done via cookies.
	my $session_management_via_cookies = 
		$ce -> {session_management_via} eq "session_cookie";
	
	debug("used_cookie='", $used_cookie, "' unused_valid_cookie='", $unused_valid_cookie, "' user_requests_cookie='", $user_requests_cookie, 
			"' session_management_via_cookies ='", $session_management_via_cookies, "'");
	
	if ($used_cookie or $unused_valid_cookie or $user_requests_cookie or $session_management_via_cookies) {
		#debug("Authen::maybe_send_cookie is sending a cookie");
		$self->sendCookie($self->{user_id}, $self->{session_key});
	} else {
		$self->killCookie;
	}
}

sub maybe_kill_cookie {
	my $self = shift;
	#$self->killCookie(@_);
}


################################################################################
# Session key management
################################################################################

sub unexpired_session_exists {
	my ($self, $userID) = @_;
	my $ce = $self->{r}->ce;
	my $db = $self->{r}->db;
	
	my $Key = $db->getKey($userID); # checked
	return 0 unless defined $Key;
	if (time <= $Key->timestamp()+$ce->{sessionKeyTimeout}) {
		# unexpired, but leave timestamp alone
		return 1;
	} else {
		# expired -- delete key
		# NEW: no longer delete the key here -- a user re-visiting with a formerly-valid key should
		# always get a "session expired" message. formerly, if they i.e. reload the login screen
		# the message disappears, which is confusing (i claim ;)
		#$db->deleteKey($userID);
		return 0;
	}
}

# clobbers any existing session for this $userID
# if $newKey is not specified, a random key is generated
# the key is returned
sub create_session {
	my ($self, $userID, $newKey) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};
	
	my $timestamp = time;
	unless ($newKey) {
		my @chars = @{ $ce->{sessionKeyChars} };
		my $length = $ce->{sessionKeyLength};
		
		srand;
		$newKey = join ("", @chars[map rand(@chars), 1 .. $length]);
	}
	
	my $Key = $db->newKey(user_id=>$userID, key=>$newKey, timestamp=>$timestamp);
	# DBFIXME this should be a REPLACE
	eval { $db->deleteKey($userID) };
	$db->addKey($Key);

	#if ($ce -> {session_management_via} eq "session_cookie"),
	#    then the subroutine maybe_send_cookie should send a cookie.

	return $newKey;
}

# returns ($sessionExists, $keyMatches, $timestampValid)
# if $updateTimestamp is true, the timestamp on a valid session is updated
sub check_session {
	my ($self, $userID, $possibleKey, $updateTimestamp) = @_;
	my $ce = $self->{ce};
	my $db = $self->{db};

	my $Key = $db->getKey($userID); # checked
	return 0 unless defined $Key;
	my $keyMatches = (defined $possibleKey and $possibleKey eq $Key->key);
	
	my $timestampValid=0;
	if ($ce -> {session_management_via} eq "session_cookie" and defined($self->{cookie_timestamp})) {
		$timestampValid = (time <= $self -> {cookie_timestamp} + $ce->{sessionKeyTimeout});
	} else {
		$timestampValid = (time <= $Key->timestamp()+$ce->{sessionKeyTimeout});
		if ($keyMatches and $timestampValid and $updateTimestamp) {
			$Key->timestamp(time);
			$db->putKey($Key);
		}
	}
	return (1, $keyMatches, $timestampValid);
}

sub killSession {
	my $self = shift;

	$self -> forget_verification;
	if ($self->{ce} -> {session_management_via} eq "session_cookie")  {
		$self -> killCookie();
	}

	my $userID = $self->{user_id};
	if (defined($userID)) {
		 $self->{db} -> deleteKey($userID);
	}
}


################################################################################
# Utilities
################################################################################

sub write_log_entry {
	my ($self, $message) = @_;
	
	my $user_id = defined $self->{user_id} ? $self->{user_id} : "";
	my $login_type = defined $self->{login_type} ? $self->{login_type} : "";
	my $credential_source = defined $self->{credential_source} ? $self->{credential_source} : "";
	
	my ($remote_host, $remote_port) = ('','');
	
	my $log_msg = "$message user_id=$user_id login_type=$login_type credential_source=$credential_source host=$remote_host port=$remote_port";
	debug("Writing to login log: '$log_msg'.\n");
	writeCourseLog($self->{ce}, "login_log", $log_msg);
}

1;
