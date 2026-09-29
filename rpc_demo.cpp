// Minimal variadic-template RPC demo.
//
// This example uses an in-process transport so it can be built and run as one
// file. Replace RpcServer::handle() with a socket send/receive operation when
// connecting it to a real network transport.

#include <cstdint>
#include <exception>
#include <functional>
#include <future>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

namespace mini_rpc {

class ByteBuffer {
public:
    std::vector<std::uint8_t> bytes;
    std::size_t read_pos = 0;

    std::size_t remaining() const {
        return bytes.size() - read_pos;
    }
};

inline void write_u8(ByteBuffer& buffer, std::uint8_t value) {
    buffer.bytes.push_back(value);
}

inline std::uint8_t read_u8(ByteBuffer& buffer) {
    if (buffer.remaining() < 1) {
        throw std::runtime_error("rpc decode failed: missing uint8");
    }
    return buffer.bytes[buffer.read_pos++];
}

inline void write_u32(ByteBuffer& buffer, std::uint32_t value) {
    // Use a fixed little-endian wire representation for this demo.
    for (int i = 0; i < 4; ++i) {
        write_u8(buffer, static_cast<std::uint8_t>((value >> (i * 8)) & 0xff));
    }
}

inline std::uint32_t read_u32(ByteBuffer& buffer) {
    if (buffer.remaining() < 4) {
        throw std::runtime_error("rpc decode failed: missing uint32");
    }

    std::uint32_t value = 0;
    for (int i = 0; i < 4; ++i) {
        value |= static_cast<std::uint32_t>(read_u8(buffer)) << (i * 8);
    }
    return value;
}

inline void write_string(ByteBuffer& buffer, std::string_view value) {
    if (value.size() > 0xffffffffu) {
        throw std::length_error("rpc encode failed: string is too long");
    }

    write_u32(buffer, static_cast<std::uint32_t>(value.size()));
    buffer.bytes.insert(buffer.bytes.end(), value.begin(), value.end());
}

inline std::string read_string(ByteBuffer& buffer) {
    const auto size = read_u32(buffer);
    if (buffer.remaining() < size) {
        throw std::runtime_error("rpc decode failed: incomplete string");
    }

    std::string value(
        reinterpret_cast<const char*>(buffer.bytes.data() + buffer.read_pos),
        size);
    buffer.read_pos += size;
    return value;
}

template <class>
inline constexpr bool dependent_false_v = false;

template <class T>
void write_value(ByteBuffer& buffer, const T& value) {
    using U = std::decay_t<T>;

    if constexpr (std::is_same_v<U, int>) {
        write_u32(buffer, static_cast<std::uint32_t>(static_cast<std::int32_t>(value)));
    } else if constexpr (std::is_same_v<U, std::uint32_t>) {
        write_u32(buffer, value);
    } else if constexpr (std::is_same_v<U, bool>) {
        write_u8(buffer, value ? 1 : 0);
    } else if constexpr (std::is_same_v<U, std::string>) {
        write_string(buffer, value);
    } else if constexpr (std::is_same_v<U, std::string_view>) {
        write_string(buffer, value);
    } else if constexpr (std::is_same_v<U, const char*> ||
                         std::is_same_v<U, char*>) {
        if (value == nullptr) {
            throw std::invalid_argument("rpc encode failed: null string");
        }
        write_string(buffer, value);
    } else {
        static_assert(dependent_false_v<U>,
                      "Add a write_value overload for this RPC argument type");
    }
}

template <class T>
T read_value(ByteBuffer& buffer) {
    using U = std::decay_t<T>;

    if constexpr (std::is_same_v<U, int>) {
        return static_cast<int>(static_cast<std::int32_t>(read_u32(buffer)));
    } else if constexpr (std::is_same_v<U, std::uint32_t>) {
        return read_u32(buffer);
    } else if constexpr (std::is_same_v<U, bool>) {
        const auto value = read_u8(buffer);
        if (value > 1) {
            throw std::runtime_error("rpc decode failed: invalid bool");
        }
        return value != 0;
    } else if constexpr (std::is_same_v<U, std::string>) {
        return read_string(buffer);
    } else {
        static_assert(dependent_false_v<U>,
                      "Add a read_value specialization for this RPC type");
    }
}

template <class... Args>
std::tuple<std::decay_t<Args>...> read_arguments(ByteBuffer& buffer) {
    // Braced initialization evaluates each decoder from left to right.
    return {read_value<std:deca:y_t<Args>>(buffer)...};
}

struct RpcResponse {
    bool ok = false;
    ByteBuffer payload;
    std::string error;

    static RpcResponse success(ByteBuffer payload = {}) {
        return {true, std::move(payload), {}};
    }

    static RpcResponse failure(std::string message) {
        return {false, {}, std::move(message)};
    }
};

template <class T>
struct RpcResult {
    bool ok = false;
    std::optional<T> value;
    std::string error;
};

template <>
struct RpcResult<void> {
    bool ok = false;
    std::string error;
};

class RpcServer {
public:
    using MethodId = std::uint32_t;
    using Handler = std::function<RpcResponse(const ByteBuffer&)>;

    // Non-const member function bound to an object reference. The object must
    // outlive the RpcServer.
    template <class R, class... Args, class C>
    void bind(MethodId method_id, C& object, R (C::*member)(Args...)) {
        bind<R, Args...>(
            method_id,
            [&object, member](Args... args) -> R {
                if constexpr (std::is_void_v<R>) {
                    (object.*member)(std::move(args)...);
                } else {
                    return (object.*member)(std::move(args)...);
                }
            });
    }

    // Const member function bound to an object reference.
    template <class R, class... Args, class C>
    void bind(
        MethodId method_id,
        const C& object,
        R (C::*member)(Args...) const) {
        bind<R, Args...>(
            method_id,
            [&object, member](Args... args) -> R {
                if constexpr (std::is_void_v<R>) {
                    (object.*member)(std::move(args)...);
                } else {
                    return (object.*member)(std::move(args)...);
                }
            });
    }

    // shared_ptr binding keeps the service object alive as long as the
    // registered RPC handler exists.
    template <class R, class... Args, class C>
    void bind_shared(
        MethodId method_id,
        std::shared_ptr<C> object,
        R (C::*member)(Args...)) {
        bind<R, Args...>(
            method_id,
            [object = std::move(object), member](Args... args) -> R {
                if constexpr (std::is_void_v<R>) {
                    ((*object).*member)(std::move(args)...);
                } else {
                    return ((*object).*member)(std::move(args)...);
                }
            });
    }

    template <class R, class... Args, class C>
    void bind_shared(
        MethodId method_id,
        std::shared_ptr<C> object,
        R (C::*member)(Args...) const) {
        bind<R, Args...>(
            method_id,
            [object = std::move(object), member](Args... args) -> R {
                if constexpr (std::is_void_v<R>) {
                    ((*object).*member)(std::move(args)...);
                } else {
                    return ((*object).*member)(std::move(args)...);
                }
            });
    }

    // Free functions, static member functions, lambdas, functors,
    // std::function, and std::bind results all use this generic overload.
    template <class R, class... Args, class Callable>
    void bind(MethodId method_id, Callable&& callable) {
        std::function<R(Args...)> function =
            std::forward<Callable>(callable);

        handlers_[method_id] =
            [function = std::move(function)](const ByteBuffer& request) {
                try {
                    ByteBuffer reader = request;
                    auto arguments = read_arguments<Args...>(reader);

                    if (reader.remaining() != 0) {
                        throw std::runtime_error(
                            "rpc decode failed: unexpected trailing bytes");
                    }

                    if constexpr (std::is_void_v<R>) {
                        std::apply(function, arguments);
                        return RpcResponse::success();
                    } else {
                        R result = std::apply(function, arguments);
                        ByteBuffer response;
                        write_value(response, result);
                        return RpcResponse::success(std::move(response));
                    }
                } catch (const std::exception& error) {
                    return RpcResponse::failure(error.what());
                } catch (...) {
                    return RpcResponse::failure("rpc server handler failed");
                }
            };
    }

    RpcResponse handle(MethodId method_id, const ByteBuffer& request) const {
        const auto it = handlers_.find(method_id);
        if (it == handlers_.end()) {
            return RpcResponse::failure("rpc method not found: " +
                                        std::to_string(method_id));
        }
        return it->second(request);
    }

private:
    std::unordered_map<MethodId, Handler> handlers_;
};

class RpcClient {
public:
    using MethodId = RpcServer::MethodId;

    explicit RpcClient(const RpcServer& server)
        : server_(server) {}

    template <class R, class... Args>
    R call(MethodId method_id, Args&&... args) const {
        ByteBuffer request;
        (write_value(request, std::forward<Args>(args)), ...);

        const RpcResponse response = server_.handle(method_id, request);
        if (!response.ok) {
            throw std::runtime_error(response.error);
        }

        ByteBuffer reader = response.payload;
        if constexpr (std::is_void_v<R>) {
            if (reader.remaining() != 0) {
                throw std::runtime_error(
                    "rpc decode failed: void response has a payload");
            }
            return;
        } else {
            R result = read_value<R>(reader);
            if (reader.remaining() != 0) {
                throw std::runtime_error(
                    "rpc decode failed: unexpected response bytes");
            }
            return result;
        }
    }

    template <class R, class Callback, class... Args>
    std::future<void> call_async(
        MethodId method_id,
        Callback&& callback,
        Args&&... args) const {
        // Store decayed copies so temporary arguments remain valid on the
        // worker thread.
        auto arguments = std::make_tuple(std::forward<Args>(args)...);
        using CallbackType = std::decay_t<Callback>;

        return std::async(
            std::launch::async,
            [this,
             method_id,
             callback = CallbackType(std::forward<Callback>(callback)),
             arguments = std::move(arguments)]() mutable {
                RpcResult<R> result;

                try {
                    if constexpr (std::is_void_v<R>) {
                        std::apply(
                            [this, method_id](const auto&... values) {
                                call<R>(method_id, values...);
                            },
                            arguments);
                        result.ok = true;
                    } else {
                        R value = std::apply(
                            [this, method_id](const auto&... values) {
                                return call<R>(method_id, values...);
                            },
                            arguments);
                        result.ok = true;
                        result.value = std::move(value);
                    }
                } catch (const std::exception& error) {
                    result.error = error.what();
                } catch (...) {
                    result.error = "rpc client call failed";
                }

                callback(std::move(result));
            });
    }

private:
    const RpcServer& server_;
};

}  // namespace mini_rpc

namespace demo {

enum MethodId : std::uint32_t {
    Add = 1,
    Print = 2,
    Multiply = 3,
    MemberAdd = 4,
    ConstMemberMultiply = 5,
    StaticSubtract = 6,
    SharedMemberAdd = 7,
    FunctorPower = 8,
    StdFunctionDivide = 9,
    StdBindAdd = 10,
    OverloadedMember = 11,
};

int add(int left, int right) {
    return left + right;
}

void print_message(std::string message) {
    std::cout << "[server] " << message << '\n';
}

class Calculator {
public:
    int add(int left, int right) {
        ++call_count_;
        return left + right;
    }

    int multiply(int left, int right) const {
        return left * right;
    }

    void print(std::string message) const {
        std::cout << "[calculator] " << message << '\n';
    }

    static int subtract(int left, int right) {
        return left - right;
    }

    int calculate(int value) const {
        return value * 10;
    }

    int calculate(std::string value) const {
        return static_cast<int>(value.size());
    }

private:
    int call_count_ = 0;
};

struct Power {
    int operator()(int base, int exponent) const {
        int result = 1;
        for (int i = 0; i < exponent; ++i) {
            result *= base;
        }
        return result;
    }
};

}  // namespace demo

int main() {
    using mini_rpc::RpcClient;
    using mini_rpc::RpcResult;
    using mini_rpc::RpcServer;

    RpcServer server;

    // 1. Global/free function.
    server.bind<int, int, int>(demo::Add, demo::add);

    // 2. Global/free function returning void.
    server.bind<void, std::string>(demo::Print, demo::print_message);

    // 3. Lambda.
    server.bind<int, int, int>(
        demo::Multiply,
        [](int left, int right) {
            return left * right;
        });

    demo::Calculator calculator;

    // 4. Non-const member function + object reference.
    // calculator must stay alive while server is using this handler.
    server.bind<int, int, int>(
        demo::MemberAdd,
        calculator,
        &demo::Calculator::add);

    // 5. Const member function + object reference.
    server.bind<int, int, int>(
        demo::ConstMemberMultiply,
        calculator,
        &demo::Calculator::multiply);

    // 6. Static member function. It has no object, so it uses the generic
    // callable overload just like a free function.
    server.bind<int, int, int>(
        demo::StaticSubtract,
        &demo::Calculator::subtract);

    // 7. Non-const member function + shared_ptr.
    // The handler owns this service object and keeps it alive.
    auto shared_calculator = std::make_shared<demo::Calculator>();
    server.bind_shared<int, int, int>(
        demo::SharedMemberAdd,
        shared_calculator,
        &demo::Calculator::add);
    shared_calculator.reset();

    // 8. Function object/functor.
    server.bind<int, int, int>(demo::FunctorPower, demo::Power{});

    // 9. std::function.
    std::function<int(int, int)> divide =
        [](int left, int right) {
            if (right == 0) {
                throw std::invalid_argument("division by zero");
            }
            return left / right;
        };
    server.bind<int, int, int>(demo::StdFunctionDivide, divide);

    // 10. std::bind result.
    auto bound_add = std::bind(
        demo::add,
        std::placeholders::_1,
        std::placeholders::_2);
    server.bind<int, int, int>(demo::StdBindAdd, bound_add);

    // 11. Overloaded member function. Select the exact overload first.
    using IntCalculatorMethod = int (demo::Calculator::*)(int) const;
    const auto calculate_int =
        static_cast<IntCalculatorMethod>(&demo::Calculator::calculate);
    server.bind<int, int>(
        demo::OverloadedMember,
        calculator,
        calculate_int);

    RpcClient client(server);

    // Synchronous calls: R is the return type and Args... are deduced.
    const int sum = client.call<int>(demo::Add, 20, 22);
    std::cout << "[client] add result = " << sum << '\n';

    client.call<void>(demo::Print, std::string("hello from client"));

    std::cout << "[client] lambda result = "
              << client.call<int>(demo::Multiply, 6, 7) << '\n';
    std::cout << "[client] member result = "
              << client.call<int>(demo::MemberAdd, 10, 5) << '\n';
    std::cout << "[client] const member result = "
              << client.call<int>(demo::ConstMemberMultiply, 6, 7) << '\n';
    std::cout << "[client] static member result = "
              << client.call<int>(demo::StaticSubtract, 10, 3) << '\n';
    std::cout << "[client] shared member result = "
              << client.call<int>(demo::SharedMemberAdd, 8, 9) << '\n';
    std::cout << "[client] functor result = "
              << client.call<int>(demo::FunctorPower, 2, 8) << '\n';
    std::cout << "[client] std::function result = "
              << client.call<int>(demo::StdFunctionDivide, 20, 4) << '\n';
    std::cout << "[client] std::bind result = "
              << client.call<int>(demo::StdBindAdd, 11, 12) << '\n';
    std::cout << "[client] overloaded member result = "
              << client.call<int>(demo::OverloadedMember, 9) << '\n';

    // Asynchronous call: callback runs on the std::async worker thread.
    auto multiply_done = client.call_async<int>(
        demo::Multiply,
        [](RpcResult<int> result) {
            if (result.ok) {
                std::cout << "[callback] multiply result = "
                          << *result.value << '\n';
            } else {
                std::cout << "[callback] multiply failed: "
                          << result.error << '\n';
            }
        },
        6,
        7);

    // Waiting here keeps the demo deterministic and makes sure the callback
    // has completed before main exits.
    multiply_done.get();

    // Errors are transported as exceptions for synchronous calls.
    try {
        client.call<int>(999, 1);
    } catch (const std::exception& error) {
        std::cout << "[client] expected error: " << error.what() << '\n';
    }

    // Errors are transported inside RpcResult for asynchronous calls.
    auto missing_done = client.call_async<void>(
        999,
        [](RpcResult<void> result) {
            std::cout << "[callback] missing method: "
                      << (result.ok ? "unexpected success" : result.error)
                      << '\n';
        });
    missing_done.get();

    return 0;
}
