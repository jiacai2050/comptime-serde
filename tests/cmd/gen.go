package main

import (
	"os"
	"path/filepath"

	pb "comptime-serde/tests"

	"google.golang.org/protobuf/proto"
)

func must(data []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return data
}

func writePayload(dir, name string, data []byte) {
	if err := os.WriteFile(filepath.Join(dir, name+".bin"), data, 0644); err != nil {
		panic(err)
	}
}

func main() {
	dir := "payloads"
	os.MkdirAll(dir, 0755)

	writePayload(dir, "simple", must(proto.Marshal(&pb.SimpleMessage{
		Name: "hello", Port: 8080, Flag: true,
	})))

	writePayload(dir, "nested", must(proto.Marshal(&pb.NestedMessage{
		Name:   "myapp",
		Server: &pb.Server{Host: "localhost", Port: 8080},
	})))

	writePayload(dir, "packed", must(proto.Marshal(&pb.PackedScalars{
		Scores: []uint32{100, 200, 300},
	})))

	writePayload(dir, "repeated", must(proto.Marshal(&pb.RepeatedMessage{
		Servers: []*pb.Server{
			{Host: "a.com", Port: 80},
			{Host: "b.com", Port: 443},
		},
	})))

	writePayload(dir, "enum", must(proto.Marshal(&pb.EnumMessage{
		Status: pb.Status_inactive,
	})))

	writePayload(dir, "signed", must(proto.Marshal(&pb.SignedMessage{
		Value: -42,
	})))

	writePayload(dir, "float", must(proto.Marshal(&pb.FloatMessage{
		F: 3.14, D: 2.71828,
	})))

	tag := "hello"
	writePayload(dir, "optional_string", must(proto.Marshal(&pb.OptionalStringMessage{
		Name: "test", Tag: &tag,
	})))

	writePayload(dir, "optional_struct", must(proto.Marshal(&pb.OptionalStructMessage{
		Name:   "app",
		Server: &pb.Server{Host: "localhost", Port: 8080},
	})))
}
