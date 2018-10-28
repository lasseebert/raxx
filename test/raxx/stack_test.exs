defmodule Raxx.StackTest do
  use ExUnit.Case

  alias Raxx.Middleware
  alias Raxx.Stack
  alias Raxx.Server

  defmodule HomePage do
    use Raxx.Server

    @impl Raxx.Server
    def handle_request(_request, _state) do
      response(:ok)
      |> set_body("Home page")
    end
  end

  defmodule NoOp do
    @behaviour Middleware

    @impl Middleware
    def process_head(request, config, inner_server) do
      {parts, inner_server} = Server.handle_head(inner_server, request)
      {parts, {config, :head}, inner_server}
    end

    @impl Middleware
    def process_data(data, {_, prev}, inner_server) do
      {parts, inner_server} = Server.handle_data(inner_server, data)
      {parts, {prev, :data}, inner_server}
    end

    @impl Middleware
    def process_tail(tail, {_, prev}, inner_server) do
      {parts, inner_server} = Server.handle_tail(inner_server, tail)
      {parts, {prev, :tail}, inner_server}
    end

    @impl Middleware
    def process_info(message, {_, prev}, inner_server) do
      {parts, inner_server} = Server.handle_info(inner_server, message)
      {parts, {prev, :info}, inner_server}
    end
  end

  test "a couple of NoOp Middlewares don't modify the response of a simple controller" do
    middlewares = [{NoOp, :irrelevant}, {NoOp, 42}]
    stack_server = make_stack_server(middlewares, HomePage, :controller_initial)

    request =
      Raxx.request(:POST, "/")
      |> Raxx.set_content_length(3)
      |> Raxx.set_body(true)

    assert {[], stack_server} = Server.handle_head(stack_server, request)
    assert {[], stack_server} = Server.handle_data(stack_server, "abc")

    assert {[response], _stack_server} = Server.handle_tail(stack_server, [])

    assert %Raxx.Response{
             body: "Home page",
             headers: [{"content-length", "9"}],
             status: 200
           } = response
  end

  defmodule Meddler do
    @behaviour Middleware
    @impl Middleware
    def process_head(request, config, inner_server) do
      request =
        case Keyword.get(config, :request_header) do
          nil ->
            request

          value ->
            request
            |> Raxx.delete_header("x-request-header")
            |> Raxx.set_header("x-request-header", value)
        end

      {parts, inner_server} = Server.handle_head(inner_server, request)
      parts = modify_parts(parts, config)
      {parts, config, inner_server}
    end

    @impl Middleware
    def process_data(data, config, inner_server) do
      {parts, inner_server} = Server.handle_data(inner_server, data)
      parts = modify_parts(parts, config)
      {parts, config, inner_server}
    end

    @impl Middleware
    def process_tail(tail, config, inner_server) do
      {parts, inner_server} = Server.handle_tail(inner_server, tail)
      parts = modify_parts(parts, config)
      {parts, config, inner_server}
    end

    @impl Middleware
    def process_info(message, config, inner_server) do
      {parts, inner_server} = Server.handle_info(inner_server, message)
      parts = modify_parts(parts, config)
      {parts, config, inner_server}
    end

    defp modify_parts(parts, config) do
      Enum.map(parts, &modify_part(&1, config))
    end

    defp modify_part(data = %Raxx.Data{data: contents}, config) do
      new_contents = modify_contents(contents, config)
      %Raxx.Data{data | data: new_contents}
    end

    # NOTE this function head is necessary if Stack doesn't do Raxx.simplify_parts/1
    defp modify_part(response = %Raxx.Response{body: contents}, config)
         when is_binary(contents) do
      new_contents = modify_contents(contents, config)
      %Raxx.Response{response | body: new_contents}
    end

    defp modify_part(part, _state) do
      part
    end

    defp modify_contents(contents, config) do
      case Keyword.get(config, :response_body) do
        nil ->
          contents

        replacement when is_binary(replacement) ->
          String.replace(contents, ~r/./, replacement)
          # make sure it's the same length
          |> String.slice(0, String.length(contents))
      end
    end
  end

  defmodule SpyServer do
    use Raxx.Server
    # this server is deliberately weird to trip up any assumptions
    @impl Raxx.Server
    def handle_head(request = %{body: false}, state) do
      send(self(), {__MODULE__, :handle_head, request, state})

      response =
        Raxx.response(:ok) |> Raxx.set_body("SpyServer responds to a request with no body")

      {[response], state}
    end

    def handle_head(request, state) do
      send(self(), {__MODULE__, :handle_head, request, state})
      {[], 1}
    end

    def handle_data(data, state) do
      send(self(), {__MODULE__, :handle_data, data, state})

      headers =
        response(:ok)
        |> set_content_length(10)
        |> set_body(true)

      {[headers], state + 1}
    end

    def handle_tail(tail, state) do
      send(self(), {__MODULE__, :handle_tail, tail, state})
      {[data("spy server"), tail([{"x-response-trailer", "spy-trailer"}])], -1 * state}
    end
  end

  test "middlewares can modify the request" do
    middlewares = [{Meddler, [request_header: "foo"]}, {Meddler, [request_header: "bar"]}]
    stack_server = make_stack_server(middlewares, SpyServer, :controller_initial)

    request =
      Raxx.request(:POST, "/")
      |> Raxx.set_content_length(3)
      |> Raxx.set_body(true)

    assert {[], stack_server} = Server.handle_head(stack_server, request)

    assert_receive {SpyServer, :handle_head, server_request, :controller_initial}
    assert %Raxx.Request{} = server_request
    assert "bar" == Raxx.get_header(server_request, "x-request-header")
    assert 3 == Raxx.get_content_length(server_request)

    assert {[headers], stack_server} = Server.handle_data(stack_server, "abc")
    assert_receive {SpyServer, :handle_data, "abc", 1}
    assert %Raxx.Response{body: true, status: 200} = headers

    assert {[data, tail], stack_server} = Server.handle_tail(stack_server, [])
    assert_receive {SpyServer, :handle_tail, [], 2}
    assert %Raxx.Data{data: "spy server"} = data
    assert %Raxx.Tail{headers: [{"x-response-trailer", "spy-trailer"}]} == tail
  end

  test "middlewares can modify the response" do
    middlewares = [{Meddler, [response_body: "foo"]}, {Meddler, [response_body: "bar"]}]
    stack_server = make_stack_server(middlewares, SpyServer, :controller_initial)

    request =
      Raxx.request(:POST, "/")
      |> Raxx.set_content_length(3)
      |> Raxx.set_body(true)

    assert {[], stack_server} = Server.handle_head(stack_server, request)

    assert_receive {SpyServer, :handle_head, server_request, :controller_initial}
    assert %Raxx.Request{} = server_request
    assert nil == Raxx.get_header(server_request, "x-request-header")
    assert 3 == Raxx.get_content_length(server_request)

    assert {[headers], stack_server} = Server.handle_data(stack_server, "abc")
    assert_receive {SpyServer, :handle_data, "abc", 1}
    assert %Raxx.Response{body: true, status: 200} = headers

    assert {[data, tail], stack_server} = Server.handle_tail(stack_server, [])
    assert_receive {SpyServer, :handle_tail, [], 2}
    assert %Raxx.Data{data: "foofoofoof"} = data
    assert %Raxx.Tail{headers: [{"x-response-trailer", "spy-trailer"}]} == tail
  end

  test "middlewares' state is correctly updated" do
    middlewares = [{Meddler, [response_body: "foo"]}, {NoOp, :config}]
    stack_server = make_stack_server(middlewares, SpyServer, :controller_initial)

    request =
      Raxx.request(:POST, "/")
      |> Raxx.set_content_length(3)
      |> Raxx.set_body(true)

    assert {_parts, stack_server} = Server.handle_head(stack_server, request)
    assert {Stack, stack} = stack_server

    assert [{Meddler, [response_body: "foo"]}, {NoOp, {:config, :head}}] ==
             Stack.get_pipeline(stack)

    assert {SpyServer, 1} == Stack.get_server(stack)

    {_parts, stack_server} = Server.handle_data(stack_server, "z")
    assert {Stack, stack} = stack_server

    assert [{Meddler, [response_body: "foo"]}, {NoOp, {:head, :data}}] ==
             Stack.get_pipeline(stack)

    assert {SpyServer, 2} == Stack.get_server(stack)

    {_parts, stack_server} = Server.handle_data(stack_server, "zz")
    assert {Stack, stack} = stack_server

    assert [{Meddler, [response_body: "foo"]}, {NoOp, {:data, :data}}] ==
             Stack.get_pipeline(stack)

    assert {SpyServer, 3} == Stack.get_server(stack)

    {_parts, stack_server} = Server.handle_tail(stack_server, [{"x-foo", "bar"}])
    assert {Stack, stack} = stack_server
    assert [{Meddler, _}, {NoOp, {:data, :tail}}] = Stack.get_pipeline(stack)
    assert {SpyServer, -3} == Stack.get_server(stack)
  end

  test "a stack with no middlewares is functional" do
    stack_server = make_stack_server([], SpyServer, :controller_initial)

    request =
      Raxx.request(:POST, "/")
      |> Raxx.set_content_length(3)
      |> Raxx.set_body(true)

    {stack_result_1, stack_server} = Server.handle_head(stack_server, request)
    {stack_result_2, stack_server} = Server.handle_data(stack_server, "xxx")
    {stack_result_3, _stack_server} = Server.handle_tail(stack_server, [])

    {server_result_1, state} = SpyServer.handle_head(request, :controller_initial)
    {server_result_2, state} = SpyServer.handle_data("xxx", state)
    {server_result_3, _state} = SpyServer.handle_tail([], state)

    assert stack_result_1 == server_result_1
    assert stack_result_2 == server_result_2
    assert stack_result_3 == server_result_3
  end

  defmodule AlwaysForbidden do
    @behaviour Middleware

    @impl Middleware
    def process_head(_request, _config, inner_server) do
      response =
        Raxx.response(:forbidden)
        |> Raxx.set_body("Forbidden!")

      {[response], nil, inner_server}
    end

    @impl Middleware
    def process_data(_data, _state, inner_server) do
      {[], nil, inner_server}
    end

    @impl Middleware
    def process_tail(_tail, _state, inner_server) do
      {[], nil, inner_server}
    end

    @impl Middleware
    def process_info(_message, _state, inner_server) do
      {[], nil, inner_server}
    end
  end

  test "middlewares can \"short circuit\" processing (not call through)" do
    middlewares = [{NoOp, nil}, {AlwaysForbidden, nil}]
    stack_server = make_stack_server(middlewares, SpyServer, :whatever)
    request = Raxx.request(:GET, "/")

    assert {[response], _stack_server} = Server.handle_head(stack_server, request)
    assert %Raxx.Response{body: "Forbidden!"} = response

    refute_receive _

    stack_server = make_stack_server([{NoOp, nil}], SpyServer, :whatever)
    assert {[response], _stack_server} = Server.handle_head(stack_server, request)
    assert response.body =~ "SpyServer"

    assert_receive {SpyServer, _, _, _}
  end

  defp make_stack_server(middlewares, server_module, server_state) do
    Stack.new(middlewares, {server_module, server_state})
    |> Stack.server()
  end
end
