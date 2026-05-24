package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"

	pb "comptime-serde/tests"

	"google.golang.org/protobuf/proto"
)

func main() {
	dir := "zig-output"
	var failures int

	failures += verify("simple", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "simple.bin"))
		if err != nil {
			return err
		}
		msg := &pb.SimpleMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("name", "hello", msg.Name)
		expect("port", uint32(8080), msg.Port)
		expect("flag", true, msg.Flag)
		return nil
	})

	failures += verify("nested", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "nested.bin"))
		if err != nil {
			return err
		}
		msg := &pb.NestedMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("name", "myapp", msg.Name)
		expect("server.host", "localhost", msg.Server.Host)
		expect("server.port", uint32(8080), msg.Server.Port)
		return nil
	})

	failures += verify("packed", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "packed.bin"))
		if err != nil {
			return err
		}
		msg := &pb.PackedScalars{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("len", 3, len(msg.Scores))
		expect("scores[0]", uint32(100), msg.Scores[0])
		expect("scores[1]", uint32(200), msg.Scores[1])
		expect("scores[2]", uint32(300), msg.Scores[2])
		return nil
	})

	failures += verify("repeated", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "repeated.bin"))
		if err != nil {
			return err
		}
		msg := &pb.RepeatedMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("len", 2, len(msg.Servers))
		expect("servers[0].host", "a.com", msg.Servers[0].Host)
		expect("servers[0].port", uint32(80), msg.Servers[0].Port)
		expect("servers[1].host", "b.com", msg.Servers[1].Host)
		expect("servers[1].port", uint32(443), msg.Servers[1].Port)
		return nil
	})

	failures += verify("enum", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "enum.bin"))
		if err != nil {
			return err
		}
		msg := &pb.EnumMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("status", pb.Status_inactive, msg.Status)
		return nil
	})

	failures += verify("signed", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "signed.bin"))
		if err != nil {
			return err
		}
		msg := &pb.SignedMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("value", int32(-42), msg.Value)
		return nil
	})

	failures += verify("float", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "float.bin"))
		if err != nil {
			return err
		}
		msg := &pb.FloatMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		if math.Abs(float64(msg.F)-3.14) > 0.001 {
			panic(fmt.Sprintf("f: got %v, want ~3.14", msg.F))
		}
		if math.Abs(msg.D-2.71828) > 0.00001 {
			panic(fmt.Sprintf("d: got %v, want ~2.71828", msg.D))
		}
		return nil
	})

	failures += verify("optional_string", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "optional_string.bin"))
		if err != nil {
			return err
		}
		msg := &pb.OptionalStringMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("name", "test", msg.Name)
		expect("tag", "hello", *msg.Tag)
		return nil
	})

	failures += verify("optional_struct", func() error {
		data, err := os.ReadFile(filepath.Join(dir, "optional_struct.bin"))
		if err != nil {
			return err
		}
		msg := &pb.OptionalStructMessage{}
		if err := proto.Unmarshal(data, msg); err != nil {
			return err
		}
		expect("name", "app", msg.Name)
		expect("server.host", "localhost", msg.Server.Host)
		expect("server.port", uint32(8080), msg.Server.Port)
		return nil
	})

	if failures > 0 {
		fmt.Fprintf(os.Stderr, "%d test(s) failed\n", failures)
		os.Exit(1)
	}
	fmt.Println("All 9 Go verification tests passed.")
}

func verify(name string, fn func() error) int {
	if err := fn(); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL %s: %v\n", name, err)
		return 1
	}
	return 0
}

func expect[T comparable](field string, want, got T) {
	if want != got {
		panic(fmt.Sprintf("%s: want %v, got %v", field, want, got))
	}
}
