%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(stanchion_manifest_fsm).

-include("riak_moss.hrl").

-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Test API
-export([test_link/2]).

-endif.

%% API
-export([start_link/3,
         get_all_manifests/1,
         get_active_manifest/1,
         get_specific_manifest/2,
         add_new_manifest/2,
         update_manifest/2,
         update_manifests/2,
         delete_specific_manifest/2,
         update_manifest_with_confirmation/2,
         update_manifests_with_confirmation/2,
         stop/1]).

%% gen_fsm callbacks
-export([init/1,

         %% async
         waiting_command/2,
         waiting_update_command/2,

         %% sync
         waiting_command/3,
         waiting_update_command/3,

         %% rest
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).

-record(state, {bucket :: binary(),
                key :: binary(),
                riak_object :: term(),
                manifests :: term(), % an orddict mapping UUID -> Manifest
                riakc_pid :: pid()
            }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Bucket, Key, RiakcPid) ->
    gen_fsm:start_link(?MODULE, [Bucket, Key, RiakcPid], []).

get_all_manifests(Pid) ->
    gen_fsm:sync_send_event(Pid, get_manifests, infinity).

get_active_manifest(Pid) ->
    case gen_fsm:sync_send_event(Pid, get_manifests, infinity) of
        {ok, Manifests} ->
            case stanchion_manifest_utils:active_manifest(Manifests) of
                {ok, _Active}=ActiveReply ->
                    ActiveReply;
                {error, no_active_manifest} ->
                    {error, notfound}
            end;
        {error, notfound}=NotFound ->
            NotFound
    end.

get_specific_manifest(Pid, UUID) ->
    case gen_fsm:sync_send_event(Pid, get_manifests, infinity) of
        {ok, Manifests} ->
            case orddict:fetch(UUID, Manifests) of
                {ok, _}=Result ->
                    Result;
                error ->
                    {error, notfound}
            end;
        {error, notfound}=NotFound ->
            NotFound
    end.

add_new_manifest(Pid, Manifest) ->
    Dict = stanchion_manifest_utils:new_dict(Manifest?MANIFEST.uuid, Manifest),
    gen_fsm:send_event(Pid, {add_new_dict, Dict}).

update_manifests(Pid, Manifests) ->
    gen_fsm:send_event(Pid, {update_manifests, Manifests}).

update_manifest(Pid, Manifest) ->
    Dict = stanchion_manifest_utils:new_dict(Manifest?MANIFEST.uuid, Manifest),
    update_manifests(Pid, Dict).

%% @doc Delete a specific manifest version from a manifest and
%% update the manifest value in riak or delete the manifest key from
%% riak if there are no manifest versions remaining.
-spec delete_specific_manifest(pid(), binary()) -> ok | {error, term()}.
delete_specific_manifest(Pid, UUID) ->
    gen_fsm:sync_send_event(Pid, {delete_manifest, UUID}, infinity).

-spec update_manifests_with_confirmation(pid(), orddict:orddict()) -> ok | {error, term()}.
update_manifests_with_confirmation(Pid, Manifests) ->
    gen_fsm:sync_send_event(Pid, {update_manifests_with_confirmation, Manifests},
                           infinity).

-spec update_manifest_with_confirmation(pid(), lfs_manifest()) -> ok | {error, term()}.
update_manifest_with_confirmation(Pid, Manifest) ->
    Dict = stanchion_manifest_utils:new_dict(Manifest?MANIFEST.uuid, Manifest),
    update_manifests_with_confirmation(Pid, Dict).

stop(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, stop, infinity).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Bucket, Key, RiakcPid]) ->
    process_flag(trap_exit, true),
    {ok, waiting_command, #state{bucket=Bucket,
                                 key=Key,
                                 riakc_pid=RiakcPid}};
init([test, Bucket, Key]) ->
    %% creating the "mock" riakc_pb_socket
    %% gen_server here
    {ok, Pid} = riakc_pb_socket_fake:start_link(),
    {ok, waiting_command, #state{bucket=Bucket, key=Key, riakc_pid=Pid}}.

%% This clause is for adding a new
%% manifest that doesn't exist yet.
%% Once it has been called _once_
%% with a particular UUID, update_manifest
%% should be used from then on out.
waiting_command({add_new_dict, WrappedManifest}, State=#state{riakc_pid=RiakcPid,
                                                           bucket=Bucket,
                                                           key=Key}) ->
    {_, RiakObj, Manifests} = get_and_update(RiakcPid, WrappedManifest, Bucket, Key),
    UpdState = State#state{riak_object=RiakObj, manifests=Manifests},
    {next_state, waiting_update_command, UpdState}.

waiting_update_command({update_manifests, WrappedManifests}, State=#state{riakc_pid=RiakcPid,
                                                                 bucket=Bucket,
                                                                 key=Key,
                                                                 riak_object=undefined,
                                                                 manifests=undefined}) ->
    _Res = get_and_update(RiakcPid, WrappedManifests, Bucket, Key),
    {next_state, waiting_update_command, State};
waiting_update_command({update_manifests, WrappedManifests}, State=#state{riakc_pid=RiakcPid,
                                                                 riak_object=PreviousRiakObject,
                                                                 manifests=PreviousManifests}) ->


    _ = update_from_previous_read(RiakcPid,
                                  PreviousRiakObject,
                                  PreviousManifests,
                                  WrappedManifests),
    {next_state, waiting_update_command, State#state{riak_object=undefined, manifests=undefined}}.


waiting_command(get_manifests, _From, State) ->
    {Reply, NewState} = handle_get_manifests(State),
    {reply, Reply, waiting_update_command, NewState};
waiting_command({delete_manifest, UUID},
                       _From,
                       State=#state{riakc_pid=RiakcPid,
                                    bucket=Bucket,
                                    key=Key,
                                    riak_object=undefined,
                                    manifests=undefined}) ->
    Reply = get_and_delete(RiakcPid, UUID, Bucket, Key),
    {reply, Reply, waiting_update_command, State}.


waiting_update_command({update_manifests_with_confirmation, WrappedManifests}, _From,
                                            State=#state{riakc_pid=RiakcPid,
                                            bucket=Bucket,
                                            key=Key,
                                            riak_object=undefined,
                                            manifests=undefined}) ->
    {Reply, _, _} = get_and_update(RiakcPid, WrappedManifests, Bucket, Key),
    {reply, Reply, waiting_update_command, State};
waiting_update_command({update_manifests_with_confirmation, WrappedManifests}, _From,
                                            State=#state{riakc_pid=RiakcPid,
                                            riak_object=PreviousRiakObject,
                                            manifests=PreviousManifests}) ->
    Reply = update_from_previous_read(RiakcPid, PreviousRiakObject,
                                  PreviousManifests, WrappedManifests),

    {reply, Reply, waiting_update_command, State#state{riak_object=undefined,
                                                       manifests=undefined}}.
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(stop, _From, _StateName, State) ->
    Reply = ok,
    {stop, normal, Reply, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Return all (resolved) manifests, or notfound
-spec handle_get_manifests(#state{}) ->
    {{ok, [lfs_manifest()]}, #state{}} | {{error, notfound}, #state{}}.
handle_get_manifests(State=#state{riakc_pid=RiakcPid,
                           bucket=Bucket,
                           key=Key}) ->
    case stanchion_utils:get_manifests(RiakcPid, Bucket, Key) of
        {ok, RiakObject, Resolved} ->
            Reply = {ok, Resolved},
            NewState = State#state{riak_object=RiakObject, manifests=Resolved},
            {Reply, NewState};
        {error, notfound}=NotFound ->
            {NotFound, State}
    end.

%% @doc Retrieve the current (resolved) value at {Bucket, Key},
%% delete the manifest corresponding to `UUID', and then
%% write the value back to Riak or delete the manifest value
%% if there are no manifests remaining.
-spec get_and_delete(pid(), binary(), binary(), binary()) -> ok |
                                                             {error, term()}.
get_and_delete(RiakcPid, UUID, Bucket, Key) ->
    case stanchion_utils:get_manifests(RiakcPid, Bucket, Key) of
        {ok, RiakObject, Manifests} ->
            ResolvedManifests = stanchion_manifest_resolution:resolve([Manifests]),
            UpdatedManifests = orddict:erase(UUID, ResolvedManifests),
            case UpdatedManifests of
                [] ->
                    ManifestBucket = stanchion_utils:to_bucket_name(objects, Bucket),
                    riakc_pb_socket:delete(RiakcPid, ManifestBucket, Key);
                _ ->
                    ObjectToWrite =
                        riakc_obj:update_value(RiakObject,
                                               term_to_binary(UpdatedManifests)),
                    stanchion_utils:put_with_no_meta(RiakcPid, ObjectToWrite)
            end;
        {error, notfound} ->
            ok
    end.

get_and_update(RiakcPid, WrappedManifests, Bucket, Key) ->
    %% retrieve the current (resolved) value at {Bucket, Key},
    %% add the new manifest, and then write the value
    %% back to Riak
    %% NOTE: it would also be nice to assert that the
    %% UUID being added doesn't already exist in the
    %% dict
    case stanchion_utils:get_manifests(RiakcPid, Bucket, Key) of
        {ok, RiakObject, Manifests} ->
            NewManiAdded = stanchion_manifest_resolution:resolve([WrappedManifests, Manifests]),
            OverwrittenUUIDs = stanchion_manifest_utils:overwritten_UUIDs(Manifests),
            case OverwrittenUUIDs of
                [] ->
                    ObjectToWrite = riakc_obj:update_value(RiakObject,
                        term_to_binary(NewManiAdded)),

                    Result = stanchion_utils:put_with_no_meta(RiakcPid, ObjectToWrite);
                _ ->
                    Result = riak_cs_gc:gc_manifests(Bucket,
                                                    Key,                                                                                     NewManiAdded,
                                                    OverwrittenUUIDs,
                                                    RiakObject,
                                                    RiakcPid)
            end,
            {Result, RiakObject, Manifests};
        {error, notfound} ->
            ManifestBucket = stanchion_utils:to_bucket_name(objects, Bucket),
            ObjectToWrite = riakc_obj:new(ManifestBucket, Key, term_to_binary(WrappedManifests)),
            PutResult = stanchion_utils:put_with_no_meta(RiakcPid, ObjectToWrite),
            {PutResult, undefined, undefined}
    end.


-spec update_from_previous_read(pid(), riakc_obj:riakc_obj(),
                                    orddict:orddict(), orddict:orddict()) ->
    ok | {error, term()}.
update_from_previous_read(RiakcPid, RiakObject,
                              PreviousManifests, NewManifests) ->
    Resolved = stanchion_manifest_resolution:resolve([PreviousManifests,
            NewManifests]),
    NewRiakObject = riakc_obj:update_value(RiakObject,
        term_to_binary(Resolved)),
    %% TODO:
    %% currently we don't do
    %% anything to make sure
    %% this call succeeded

    stanchion_utils:put_with_no_meta(RiakcPid, NewRiakObject).

%% ===================================================================
%% Test API
%% ===================================================================

-ifdef(TEST).

test_link(Bucket, Key) ->
    gen_fsm:start_link(?MODULE, [test, Bucket, Key], []).

-endif.
