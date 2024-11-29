-module(hb_path).
-export([push/3, push_hashpath/2, push_request/2]).
-export([queue_request/2, pop_request/1]).
-export([verify_hashpath/3]).
-export([term_to_path/1, term_to_path/2, from_message/2]).
-include("include/hb.hrl").

%%% @moduledoc This module provides utilities for manipulating the paths of a
%%% message: Its request path (referred to in messages as just the `Path`), and
%%% its HashPath.
%%% 
%%% A HashPath is a rolling Merkle list of the messages that have been applied 
%%% in order to generate a given message. Because applied messages can
%%% themselves be the result of message applications with the Permaweb Abstract
%%% Machine (PAM), the HashPath can be thought of as the tree of messages that
%%% represent the history of a given message. The initial message on a HashPath
%%% is referred to by its ID and serves as its user-generated 'root'.
%%% 
%%% Specifically, the HashPath can be generated by hashing the previous HashPath
%%% and the current message. This means that each message in the HashPath is
%%% dependent on all previous messages.
%%% 
%%%     Msg1.HashPath = Msg1.ID
%%%     Msg3.HashPath = Msg1.Hash(Msg1.HashPath, Msg2.ID)
%%%     Msg3.{...} = PAM.apply(Msg1, Msg2)
%%%     ...
%%% 
%%% A message's ID itself includes its HashPath, leading to the mixing of
%%% a Msg2's merkle list into the resulting Msg3's HashPath. This allows a single
%%% message to represent a history _tree_ of all of the messages that were
%%% applied to generate it -- rather than just a linear history.
%%% 
%%% A message may also specify its own algorithm for generating its HashPath,
%%% which allows for custom logic to be used for representing the history of a
%%% message. When Msg2's are applied to a Msg1, the resulting Msg3's HashPath
%%% will be generated according to Msg1's algorithm choice.

%% @doc Add a path element to a message, according to the type given.
push(hashpath, Msg3, Msg2) ->
	push_hashpath(Msg3, Msg2);
push(request, Msg3, Msg2) ->
	push_request(Msg3, Msg2).

%%% @doc Add an ID of a Msg2 to the HashPath of another message.
push_hashpath(Msg, Msg2) when is_map(Msg2) ->
	{ok, Msg2ID} = dev_message:unsigned_id(Msg2),
	push_hashpath(Msg, Msg2ID);
push_hashpath(Msg, Msg2ID) ->
	?no_prod("We should use the signed ID if the message is being"
		" invoked with it."),
	MsgHashpath = from_message(hashpath, Msg),
	HashpathFun = hashpath_function(Msg),
	NewHashpath = HashpathFun(MsgHashpath, Msg2ID),
	{ok, TransformedMsg} =
		dev_message:set(
			Msg,
			#{ hashpath => NewHashpath },
			#{}
		),
	TransformedMsg.

%%% @doc Get the hashpath function for a message from its HashPath-Alg.
%%% If no hashpath algorithm is specified, the protocol defaults to
%%% `sha-256-chain`.
hashpath_function(Msg) ->
	case dev_message:get(<<"Hashpath-Alg">>, Msg) of
		{ok, <<"sha-256-chain">>} ->
			fun hb_crypto:sha256_chain/2;
		{ok, <<"accumulate-256">>} ->
			fun hb_crypto:accumulate/2;
		{error, not_found} ->
			fun hb_crypto:sha256_chain/2
	end.

%%% @doc Add a message to the head (next to execute) of a request path.
push_request(Msg, Path) ->
	maps:put(path, term_to_path(Path) ++ from_message(request, Msg), Msg).

%%% @doc Pop a message from a request path.
pop_request(Msg) when is_map(Msg) ->
	[Head|Rest] = from_message(request, Msg),
	{Head, Rest}.

%%% @doc Queue a message at the back of a request path. `path` is the only
%%% key that we cannot use dev_message's `set/3` function for (as it expects
%%% the compute path to be there), so we use maps:put/3 instead.
queue_request(Msg, Path) ->
	maps:put(path, from_message(request, Msg) ++ term_to_path(Path), Msg).
	
%%% @doc Verify the HashPath of a message, given a list of messages that
%%% represent its history. Only takes the last message's HashPath-Alg into
%%% account, so shouldn't be used in production yet.
verify_hashpath(InitialMsg, CurrentMsg, MsgList) when is_map(InitialMsg) ->
	{ok, InitialMsgID} = dev_message:unsigned_id(InitialMsg),
	verify_hashpath(InitialMsgID, CurrentMsg, MsgList);
verify_hashpath(InitialMsgID, CurrentMsg, MsgList) ->
	?no_prod("Must trace if the Hashpath-Alg has changed between messages."),
	HashpathFun = hashpath_function(CurrentMsg),
	lists:foldl(
		fun(MsgApplied, Acc) ->
			MsgID =
				case is_map(MsgApplied) of
					true ->
						{ok, ID} = dev_message:unsigned_id(MsgApplied),
						ID;
					false -> MsgApplied
				end,
			HashpathFun(Acc, MsgID)
		end,
		InitialMsgID,
		MsgList
	).

%% @doc Extract the request path or hashpath from a message. We do not use
%% PAM for this resolution because this function is called from inside PAM 
%% itself. This imparts a requirement: the message's device must store a 
%% viable hashpath and path in its Erlang map at all times, unless the message
%% is directly from a user (in which case paths and hashpaths will not have 
%% been assigned yet).
from_message(hashpath, #{ hashpath := HashPath }) ->
	HashPath;
from_message(hashpath, Msg) ->
	?no_prod("We should use the signed ID if the message is being"
		" invoked with it."),
	{ok, Path} = dev_message:unsigned_id(Msg),
	term_to_path(Path);
from_message(request, #{ path := Path }) ->
	term_to_path(Path);
from_message(request, Msg) ->
	?no_prod("We should use the signed ID if the message is being"
		" invoked with it."),
	{ok, Path} = dev_message:unsigned_id(Msg),
	term_to_path(Path).

%% @doc Convert a term into an executable path. Supports binaries, lists, and
%% atoms. Notably, it does not support strings as lists of characters.
term_to_path(Path) -> term_to_path(Path, #{ error_strategy => throw }).
term_to_path(Binary, Opts) when is_binary(Binary) ->
	%?event({to_path, Binary}),
	case binary:match(Binary, <<"/">>) of
		nomatch -> [Binary];
		_ ->
			term_to_path(
				lists:filter(
					fun(Part) -> byte_size(Part) > 0 end,
					binary:split(Binary, <<"/">>, [global])
				),
				Opts
			)
	end;
term_to_path(List, Opts) when is_list(List) ->
	lists:map(fun(Part) -> hb_pam:to_key(Part, Opts) end, List);
term_to_path(Atom, _Opts) when is_atom(Atom) -> [Atom].