%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(bucket_bouncer_wm_buckets).

-export([init/1,
         service_available/2,
         authorized/2,
         content_types_provided/2,
         malformed_request/2,
         to_xml/2,
         allowed_methods/2,
         content_types_accepted/2,
         accept_body/2]).

-include("bucket_bouncer.hrl").
-include_lib("webmachine/include/webmachine.hrl").


init(_Config) ->
    {ok, #context{}}.

-spec service_available(term(), term()) -> {true, term(), term()}.
service_available(RD, Ctx) ->
    bucket_bouncer_wm_utils:service_available(RD, Ctx).

-spec malformed_request(term(), term()) -> {false, term(), term()}.
malformed_request(RD, Ctx) ->
    {false, RD, Ctx}.

%% @doc Check that the request is from the admin user
authorized(RD, Ctx) ->
    AuthHeader = wrq:get_req_header("authorization", RD),
    case bucket_bouncer_wm_utils:parse_auth_header(AuthHeader) of
        {ok, AuthMod, Args} ->
            case AuthMod:authenticate(RD, Args) of
                ok ->
                    %% Authentication succeeded
                    {true, RD, Ctx};
                {error, _Reason} ->
                    %% Authentication failed, deny access
                    bucket_bouncer_response:api_error(access_denied, RD, Ctx)
            end
    end.

%% @doc Get the list of methods this resource supports.
-spec allowed_methods(term(), term()) -> {[atom()], term(), term()}.
allowed_methods(RD, Ctx) ->
    {['GET', 'POST'], RD, Ctx}.

-spec content_types_provided(term(), term()) ->
                                    {[{string(), atom()}], term(), term()}.
content_types_provided(RD, Ctx) ->
    %% @TODO Add JSON support
    {[{"application/xml", to_xml}], RD, Ctx}.

%% @spec content_types_accepted(reqdata(), context()) ->
%%          {[{ContentType::string(), Acceptor::atom()}],
%%           reqdata(), context()}
content_types_accepted(RD, Ctx) ->
    case wrq:get_req_header("content-type", RD) of
        undefined ->
            {[{"application/octet-stream", accept_body}], RD, Ctx};
        CType ->
            {[{CType, accept_body}], RD, Ctx}
    end.


-spec to_xml(term(), term()) ->
                    {iolist(), term(), term()}.
to_xml(RD, Ctx=#context{owner_id=OwnerId}) ->
    Buckets = bucket_bouncer_utils:get_buckets(OwnerId),
    bucket_bouncer_response:list_bucket_response(Buckets,
                                                 RD,
                                                 Ctx).
%% TODO:
%% Add content_types_accepted when we add
%% in PUT and POST requests.
accept_body(ReqData, Ctx) ->
    Bucket = list_to_binary(wrq:get_qs_value("name", "", ReqData)),
    RequesterId = list_to_binary(wrq:get_qs_value("requester", "", ReqData)),
    case bucket_bouncer_server:create_bucket(Bucket, RequesterId) of
        ok ->
            {{halt, 200}, ReqData, Ctx};
        {error, Reason} ->
            riak_moss_s3_response:api_error(Reason, ReqData, Ctx)
    end.
