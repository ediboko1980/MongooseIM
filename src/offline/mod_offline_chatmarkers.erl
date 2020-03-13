%%%----------------------------------------------------------------------------
%%% @copyright (C) 2020, Erlang Solutions Ltd.
%%% @doc
%%%   this module optimizes offline storage for chat markers
%%% @end
%%%----------------------------------------------------------------------------
-module(mod_offline_chatmarkers).
-xep([{xep, 160}, {version, "1.0"}]).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

%% gen_mod handlers
-export([start/2, stop/1]).

%% Hook handlers
-export([inspect_packet/4,
         remove_user/3,
         pop_offline_messages/3]).

-include("mongoose.hrl").
-include("jlib.hrl").
-include_lib("exml/include/exml.hrl").

%% ------------------------------------------------------------------
%% Backend callbacks

-callback init(Host :: jid:lserver(), Opts :: list()) -> ok.
-callback get(Jid :: jid:jid()) -> {ok, [{Thread :: undefined | binary(),
                                          Room :: undefined | jid:jid(),
                                          TS :: erlang:timestamp()}]}.
-callback maybe_store(Jid :: jid:jid(), Thread :: undefined | binary(),
                      Room :: undefined | jid:jid(), TS :: erlang:timestamp()) -> ok.
-callback remove_user(Jid :: jid:jid()) -> ok.

%% gen_mod callbacks
%% ------------------------------------------------------------------

start(Host, Opts) ->
    gen_mod:start_backend_module(?MODULE, add_default_backend(Opts)),
    mod_offline_chatmarkers_backend:init(Host, Opts),
    ejabberd_hooks:add(hooks(Host)),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(hooks(Host)),
    ok.

hooks(Host) ->
    DefaultHooks = [
        {offline_message_hook, Host, ?MODULE, inspect_packet, 40},
        {resend_offline_messages_hook, Host, ?MODULE, pop_offline_messages, 60},
        {remove_user, Host, ?MODULE, remove_user, 50}
    ],
    case gen_mod:get_module_opt(Host, ?MODULE, store_groupchat_messages, false) of
        true ->
            GroupChatHook = {offline_groupchat_message_hook,
                             Host, ?MODULE, inspect_packet, 40},
            [GroupChatHook | DefaultHooks];
        _ -> DefaultHooks
    end.

remove_user(Acc, User, Server) ->
    mod_offline_chatmarkers_backend:remove_user(jid:make(User, Server, <<"">>)),
    Acc.

pop_offline_messages(Acc, User, Server) ->
    mongoose_acc:append(offline, messages, offline_chatmarkers(Acc, User, Server), Acc).

inspect_packet(Acc, From, To, Packet) ->
    case maybe_store_chat_marker(Acc, From, To, Packet) of
        true ->
            {stop, mongoose_acc:set(offline, stored, true, Acc)};
        false ->
            Acc
    end.

maybe_store_chat_marker(Acc, From, To, Packet) ->
    %% revert this change, muclight must forward permanent acc fields!
    case exml_query:subelement_with_ns(Packet, ?NS_CHAT_MARKERS) of
        undefined -> false;
        _ ->
            Timestamp = shift(mongoose_acc:timestamp(Acc)),
            Room = get_room(Acc, From),
            Thread = get_thread(Packet),
            mod_offline_chatmarkers_backend:maybe_store(To, Thread, Room, Timestamp),
            true
    end.

shift(TS) ->
    usec:to_now(usec:from_now(TS) - usec:from_now({0, 10, 0})).

get_room(Acc, From) ->
    case mongoose_acc:stanza_type(Acc) of
        <<"groupchat">> -> From;
        _ -> undefined
    end.

get_thread(El) ->
    case exml_query:path(El, [{element, <<"thread">>}, cdata]) of
        Thread when Thread =/= <<>> -> Thread;
        _ -> undefined
    end.

offline_chatmarkers(Acc, User, Server) ->
    JID = jid:make(User, Server, <<"">>),
    {ok, Rows} = mod_offline_chatmarkers_backend:get(JID),
    mod_offline_chatmarkers_backend:remove_user(JID),
    lists:concat([process_row(Acc, JID, R) || R <- Rows]).

process_row(Acc, Jid, {Thread, undefined, TS}) ->
    ChatMarkers = mod_smart_markers:get_chat_markers(one2one, Jid, Thread, TS),
    [build_one2one_chatmarker_msg(Acc, CM) || CM <- ChatMarkers];
process_row(Acc, Jid, {Thread, Room, TS}) ->
    ChatMarkers = mod_smart_markers:get_chat_markers(groupchat, Room, Thread, TS),
    [build_room_chatmarker_msg(Acc, Jid, CM) || CM <- ChatMarkers].

build_one2one_chatmarker_msg(Acc, CM) ->
    #{from := From, to := To, thread := Thread,
      type := Type, id := Id, timestamp := TS} = CM,
    Children = thread(Thread) ++ marker(Type, Id),
    Attributes = [{<<"from">>, jid:to_binary(From)},
                  {<<"to">>, jid:to_binary(To)}],
    Packet = #xmlel{name = <<"message">>, attrs = Attributes, children = Children},
    make_route_item(Acc, From, To, TS, Packet).

build_room_chatmarker_msg(Acc, To, CM) ->
    #{from := FromUser, to := Room, thread := Thread,
      type := Type, id := Id, timestamp := TS} = CM,
    FromUserBin = jid:to_binary(jid:to_lus(FromUser)),
    From = jid:make(Room#jid.luser, Room#jid.lserver, FromUserBin),
    FromBin = jid:to_binary(From),
    Children = thread(Thread) ++ marker(Type, Id),
    Attributes = [{<<"from">>, FromBin},
                  {<<"to">>, jid:to_binary(To)},
                  {<<"type">>, <<"groupchat">>}],
    Packet = #xmlel{name = <<"message">>, attrs = Attributes, children = Children},
    make_route_item(Acc, From, To, TS, Packet).

make_route_item(Acc, From, To, TS, Packet) ->
    NewStanzaParams = #{element => Packet, from_jid => From, to_jid => To},
    Acc1 = mongoose_acc:update_stanza(NewStanzaParams, Acc),
    Acc2 = mongoose_acc:set_permanent(mod_smart_markers, timestamp, TS, Acc1),
    {route, From, To, Acc2}.

marker(Type, Id) ->
    [#xmlel{name = atom_to_binary(Type, latin1),
        attrs = [{<<"xmlns">>, <<"urn:xmpp:chat-markers:0">>},
                 {<<"id">>, Id}], children = []}].

thread(undefined) -> [];
thread(Thread) ->
    [#xmlel{name     = <<"thread">>, attrs = [],
            children = [#xmlcdata{content = Thread}]}].

add_default_backend(Opts) ->
    case lists:keyfind(backend, 2, Opts) of
        false ->
            [{backend, rdbms} | Opts];
        _ ->
            Opts
    end.