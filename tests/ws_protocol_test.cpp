#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "WsProtocolParser.hpp"
#include "crc.hpp"

namespace {

using WsProtocolParser::FRAME_SIZE;
using WsProtocolParser::NavigationCommand;

std::array<uint8_t, FRAME_SIZE> MakeFrame(float vx, float vy, float wz) {
  std::array<uint8_t, FRAME_SIZE> frame{};
  frame[0] = WsProtocolParser::SOF;
  frame[1] = WsProtocolParser::PAYLOAD_LENGTH;
  frame[2] = WsProtocolParser::ROBOT_COMMAND_ID;
  std::memcpy(frame.data() + WsProtocolParser::VX_OFFSET, &vx, sizeof(vx));
  std::memcpy(frame.data() + WsProtocolParser::VY_OFFSET, &vy, sizeof(vy));
  std::memcpy(frame.data() + WsProtocolParser::WZ_OFFSET, &wz, sizeof(wz));
  frame[3] = LibXR::CRC8::Calculate(frame.data(), 3U);
  const uint16_t CRC = LibXR::CRC16::Calculate(frame.data(), FRAME_SIZE - 2U);
  frame[FRAME_SIZE - 2U] = static_cast<uint8_t>(CRC & 0x00FFU);
  frame[FRAME_SIZE - 1U] = static_cast<uint8_t>(CRC >> 8U);
  return frame;
}

bool Feed(WsProtocolParser::Parser& parser,
          const std::array<uint8_t, FRAME_SIZE>& frame,
          NavigationCommand& command) {
  bool published = false;
  for (const uint8_t byte : frame) {
    published = parser.Push(byte, command) || published;
  }
  return published;
}

void AssertCommand(const NavigationCommand& command, float vx, float vy,
                   float wz) {
  constexpr float EPSILON = 0.0001F;
  assert(std::fabs(command.vx - vx) < EPSILON);
  assert(std::fabs(command.vy - vy) < EPSILON);
  assert(std::fabs(command.wz - wz) < EPSILON);
}

}  // namespace

int main() {
  const auto valid = MakeFrame(1.25F, -2.5F, 0.75F);
  WsProtocolParser::Parser parser;
  NavigationCommand command{};

  assert(Feed(parser, valid, command));
  AssertCommand(command, 1.25F, -2.5F, 0.75F);

  parser.Reset();
  for (size_t index = 0; index < 17U; ++index) {
    assert(!parser.Push(valid[index], command));
  }
  for (size_t index = 17U; index < valid.size(); ++index) {
    const bool EXPECTED_PUBLISH = index + 1U == valid.size();
    assert(parser.Push(valid[index], command) == EXPECTED_PUBLISH);
  }
  AssertCommand(command, 1.25F, -2.5F, 0.75F);

  parser.Reset();
  assert(!parser.Push(0x00U, command));
  assert(!parser.Push(0xA5U, command));
  assert(Feed(parser, valid, command));

  auto bad_crc8 = valid;
  bad_crc8[3] ^= 0x01U;
  parser.Reset();
  assert(!Feed(parser, bad_crc8, command));

  auto bad_crc16 = valid;
  bad_crc16[64] ^= 0x01U;
  parser.Reset();
  assert(!Feed(parser, bad_crc16, command));

  auto bad_length = valid;
  bad_length[1] = WsProtocolParser::PAYLOAD_LENGTH - 1U;
  bad_length[3] = LibXR::CRC8::Calculate(bad_length.data(), 3U);
  parser.Reset();
  assert(!Feed(parser, bad_length, command));

  auto bad_id = valid;
  bad_id[2] = WsProtocolParser::ROBOT_COMMAND_ID + 1U;
  bad_id[3] = LibXR::CRC8::Calculate(bad_id.data(), 3U);
  parser.Reset();
  assert(!Feed(parser, bad_id, command));
}
