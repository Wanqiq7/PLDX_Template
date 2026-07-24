#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
need() { rg -Fq -- "$1" "$2" || { echo "missing: $3" >&2; exit 1; }; }
check_i2c1_contract() {
  awk '
    function without_comments(line, result, end_index) {
      result = ""
      while (length(line)) {
        if (in_comment) {
          end_index = index(line, "*/")
          if (!end_index) {
            return result
          }
          line = substr(line, end_index + 2)
          in_comment = 0
        } else if (substr(line, 1, 2) == "/*") {
          in_comment = 1
          line = substr(line, 3)
        } else if (substr(line, 1, 2) == "//") {
          return result
        } else {
          result = result substr(line, 1, 1)
          line = substr(line, 2)
        }
      }
      return result
    }
    function brace_delta(line, opens, closes) {
      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      return opens - closes
    }
    FILENAME == ARGV[1] {
      line = without_comments($0)
      if (line ~ /^[[:space:]]*static[[:space:]]+constexpr[[:space:]]+uint32_t[[:space:]]+I2C_DMA_DISABLED_THRESHOLD[[:space:]]*=/) {
        definitions++
        if (line ~ /^[[:space:]]*static[[:space:]]+constexpr[[:space:]]+uint32_t[[:space:]]+I2C_DMA_DISABLED_THRESHOLD[[:space:]]*=[[:space:]]*UINT32_MAX[[:space:]]*;[[:space:]]*$/) {
          correct_definitions++
        }
      }
      if (line ~ /^[[:space:]]*STM32I2C[[:space:]]+i2c1[[:space:]]*\([[:space:]]*&hi2c1[[:space:]]*,[[:space:]]*i2c1_buf[[:space:]]*,[[:space:]]*I2C_DMA_DISABLED_THRESHOLD[[:space:]]*\)[[:space:]]*;[[:space:]]*$/) {
        registrations++
      }
      next
    }
    FILENAME == ARGV[2] {
      line = without_comments($0)
      if (!in_function) {
        if (line ~ /void[[:space:]]+HAL_I2C_MspInit[[:space:]]*\(/ && line !~ /;/) {
          function_header_seen = 1
        }
        if (function_header_seen && index(line, "{")) {
          in_function = 1
          depth = brace_delta(line)
        }
        next
      }

      if (!in_i2c1_branch && line ~ /if[[:space:]]*\([^)]*hi2c->Instance[[:space:]]*==[[:space:]]*I2C1/) {
        i2c1_branch_pending = 1
      }

      if (in_i2c1_branch && index(line, "__HAL_LINKDMA")) {
        dma_linked = 1
      }

      delta = brace_delta(line)
      depth += delta
      if (i2c1_branch_pending && index(line, "{")) {
        in_i2c1_branch = 1
        i2c1_branch_depth = depth
        i2c1_branch_found = 1
        i2c1_branch_pending = 0
        if (index(line, "__HAL_LINKDMA")) {
          dma_linked = 1
        }
      }
      if (in_i2c1_branch && depth < i2c1_branch_depth) {
        in_i2c1_branch = 0
      }
      if (depth <= 0) {
        function_complete = 1
        in_function = 0
        function_header_seen = 0
        nextfile
      }
    }
    END {
      if (definitions != 1 || correct_definitions != 1) {
        print "missing: I2C1 truthful threshold" > "/dev/stderr"
        exit 1
      }
      if (registrations != 1) {
        print "missing: I2C1 polling registration" > "/dev/stderr"
        exit 1
      }
      if (!function_complete || !i2c1_branch_found || dma_linked) {
        print "unexpected: I2C1 DMA linkage" > "/dev/stderr"
        exit 1
      }
    }
  ' "$1" "$2"
}
need_handler_dispatch() {
  awk -v handler="$1" -v dispatch="$2" '
    $0 ~ "^[[:space:]]*void[[:space:]]+" handler "[[:space:]]*\\(" {
      in_handler = 1
    }
    in_handler {
      opened = gsub(/\{/, "{")
      closed = gsub(/\}/, "}")
      depth += opened - closed
      if (index($0, dispatch)) {
        found = 1
      }
      if (opened > 0) {
        body_started = 1
      }
      if (body_started && depth == 0) {
        exit(found ? 0 : 1)
      }
    }
    END {
      if (!body_started || !found) {
        exit 1
      }
    }
  ' "$3" || { echo "missing: $4" >&2; exit 1; }
}

check_i2c1() {
  check_i2c1_contract "$root/User/app_main.cpp" \
    "$root/Core/Src/stm32f4xx_hal_msp.c"
}

check_runtime_stats() {
  need 'FREERTOS.configGENERATE_RUN_TIME_STATS=0' "$root/DevC.ioc" \
    'runtime stats CubeMX setting'
  awk '
    /^[[:space:]]*#define[[:space:]]+configGENERATE_RUN_TIME_STATS/ {
      definitions++
      if ($3 == "0") {
        disabled++
      }
    }
    /^[[:space:]]*#define[[:space:]]+port(CONFIGURE_TIMER_FOR_RUN_TIME_STATS|GET_RUN_TIME_COUNTER_VALUE)/ {
      active_port_macros++
    }
    END {
      if (definitions > 1 || disabled != definitions || active_port_macros != 0) {
        exit 1
      }
    }
  ' "$root/Core/Inc/FreeRTOSConfig.h" || {
    echo 'missing: disabled runtime statistics config' >&2
    exit 1
  }
}

check_interrupt_wiring() {
  need 'EXTI1_IRQn' "$root/User/app_main.cpp" 'IMU EXTI registration'
  need 'NVIC.EXTI1_IRQn=true\:5\:0' "$root/DevC.ioc" 'EXTI1 priority'
  need 'NVIC.CAN1_SCE_IRQn=true\:5\:0' "$root/DevC.ioc" 'CAN1 SCE priority'
  need 'NVIC.CAN2_SCE_IRQn=true\:5\:0' "$root/DevC.ioc" 'CAN2 SCE priority'
  need 'void EXTI1_IRQHandler(void);' "$root/Core/Inc/stm32f4xx_it.h" 'EXTI1 header declaration'
  need 'void CAN1_SCE_IRQHandler(void);' "$root/Core/Inc/stm32f4xx_it.h" 'CAN1 SCE header declaration'
  need 'void CAN2_SCE_IRQHandler(void);' "$root/Core/Inc/stm32f4xx_it.h" 'CAN2 SCE header declaration'
  need 'HAL_NVIC_SetPriority(EXTI1_IRQn, 5, 0);' "$root/Core/Src/main.c" 'EXTI1 NVIC'
  need 'HAL_NVIC_EnableIRQ(EXTI1_IRQn);' "$root/Core/Src/main.c" 'EXTI1 NVIC'
  need 'HAL_NVIC_SetPriority(CAN1_SCE_IRQn, 5, 0);' "$root/Core/Src/stm32f4xx_hal_msp.c" 'CAN1 SCE NVIC'
  need 'HAL_NVIC_EnableIRQ(CAN1_SCE_IRQn);' "$root/Core/Src/stm32f4xx_hal_msp.c" 'CAN1 SCE NVIC'
  need 'HAL_NVIC_SetPriority(CAN2_SCE_IRQn, 5, 0);' "$root/Core/Src/stm32f4xx_hal_msp.c" 'CAN2 SCE NVIC'
  need 'HAL_NVIC_EnableIRQ(CAN2_SCE_IRQn);' "$root/Core/Src/stm32f4xx_hal_msp.c" 'CAN2 SCE NVIC'
  need 'EXTI1_IRQHandler' "$root/Core/Src/stm32f4xx_it.c" 'EXTI1 handler'
  need_handler_dispatch 'EXTI1_IRQHandler' 'HAL_GPIO_EXTI_IRQHandler(IMU_INT_Pin)' "$root/Core/Src/stm32f4xx_it.c" 'IMU HAL dispatch'
  need 'CAN1_SCE_IRQHandler' "$root/Core/Src/stm32f4xx_it.c" 'CAN1 SCE handler'
  need_handler_dispatch 'CAN1_SCE_IRQHandler' 'HAL_CAN_IRQHandler(&hcan1)' "$root/Core/Src/stm32f4xx_it.c" 'CAN1 HAL dispatch'
  need 'CAN2_SCE_IRQHandler' "$root/Core/Src/stm32f4xx_it.c" 'CAN2 SCE handler'
  need_handler_dispatch 'CAN2_SCE_IRQHandler' 'HAL_CAN_IRQHandler(&hcan2)' "$root/Core/Src/stm32f4xx_it.c" 'CAN2 HAL dispatch'
}

case "${1:-}" in
  '') check_interrupt_wiring; check_i2c1; check_runtime_stats ;;
  --i2c1) check_i2c1 ;;
  --runtime-stats) check_runtime_stats ;;
  *) echo "usage: $0 [--i2c1|--runtime-stats]" >&2; exit 2 ;;
esac
echo 'PASS: platform wiring'
