%%% @doc A simple JSON codec for HyperBEAM's message format. Takes a
%%% message as TABM and returns an encoded JSON string representation.
%%% This codec utilizes the httpsig@1.0 codec for signing and verifying.
-module(dev_codec_json).
-export([to/1, from/1, attest/3, verify/3, attested/1]).

to(Msg) -> iolist_to_binary(json:encode(Msg)).

from(Json) -> json:decode(Json).

attest(Msg, Req, Opts) -> dev_codec_httpsig:attest(Msg, Req, Opts).

verify(Msg, Req, Opts) -> dev_codec_httpsig:verify(Msg, Req, Opts).

attested(Msg) when is_binary(Msg) -> attested(from(Msg));
attested(Msg) -> hb_message:attested(Msg).
