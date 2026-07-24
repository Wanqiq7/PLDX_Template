#!/usr/bin/env python3
"""Regression tests for the platform interrupt wiring checker."""

from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "tools/check_platform_wiring.sh"
IT_SOURCE = """\
void EXTI1_IRQHandler(void) {
  HAL_GPIO_EXTI_IRQHandler(IMU_INT_Pin);
}

void EXTI0_IRQHandler(void) {
  HAL_GPIO_EXTI_IRQHandler(IMU_INT_Pin);
}

void CAN1_SCE_IRQHandler(void) {
  HAL_CAN_IRQHandler(&hcan1);
}

void CAN1_TX_IRQHandler(void) {
  HAL_CAN_IRQHandler(&hcan1);
}

void CAN2_SCE_IRQHandler(void) {
  HAL_CAN_IRQHandler(&hcan2);
}

void CAN2_TX_IRQHandler(void) {
  HAL_CAN_IRQHandler(&hcan2);
}
"""

IT_HEADER = """\
void EXTI1_IRQHandler(void);
void CAN1_SCE_IRQHandler(void);
void CAN2_SCE_IRQHandler(void);
"""

GPIO_SOURCE = """\
HAL_NVIC_SetPriority(EXTI1_IRQn, 5, 0);
HAL_NVIC_EnableIRQ(EXTI1_IRQn);
"""

CAN_MSP_SOURCE = """\
HAL_NVIC_SetPriority(CAN1_SCE_IRQn, 5, 0);
HAL_NVIC_EnableIRQ(CAN1_SCE_IRQn);
HAL_NVIC_SetPriority(CAN2_SCE_IRQn, 5, 0);
HAL_NVIC_EnableIRQ(CAN2_SCE_IRQn);
"""

I2C_MSP_SOURCE = """\
void HAL_I2C_MspInit(I2C_HandleTypeDef* hi2c)
{
  if (hi2c->Instance == I2C1) {
  }
  else if (hi2c->Instance == I2C3) {
    __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c3_rx);
  }
}
"""

REORDERED_I2C_MSP_SOURCE = """\
void unrelated(I2C_HandleTypeDef* hi2c)
{
  if (hi2c->Instance == I2C1) {
  }
  else if (hi2c->Instance == I2C3) {
  }
}

void HAL_I2C_MspInit(I2C_HandleTypeDef* hi2c)
{
  if (hi2c->Instance == I2C3) {
    __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c3_rx);
  }
  else if (hi2c->Instance == I2C1) {
    __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c1_rx);
  }
}
"""

DEINIT_ONLY_I2C_MSP_SOURCE = """\
void HAL_I2C_MspInit(I2C_HandleTypeDef* hi2c)
{
  if (hi2c->Instance == I2C3) {
    __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c3_rx);
  }
}

void HAL_I2C_MspDeInit(I2C_HandleTypeDef* hi2c)
{
  if (hi2c->Instance == I2C1) {
    __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c1_rx);
  }
}
"""

APP_SOURCE = """\
EXTI1_IRQn
static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = UINT32_MAX;
STM32I2C i2c1(&hi2c1, i2c1_buf, I2C_DMA_DISABLED_THRESHOLD);
"""

RUNTIME_STATS_CONFIG = """\
#define configGENERATE_RUN_TIME_STATS 0
"""


class PlatformWiringCheckTest(unittest.TestCase):
    def run_checker(
        self,
        source=IT_SOURCE,
        header=IT_HEADER,
        gpio_source=GPIO_SOURCE,
        can_msp_source=CAN_MSP_SOURCE,
        i2c_msp_source=I2C_MSP_SOURCE,
        app_source=APP_SOURCE,
        runtime_stats_config=RUNTIME_STATS_CONFIG,
        ioc_source="NVIC.EXTI1_IRQn=true\\:5\\:0\\nNVIC.CAN1_SCE_IRQn=true\\:5\\:0\\nNVIC.CAN2_SCE_IRQn=true\\:5\\:0\\nFREERTOS.configGENERATE_RUN_TIME_STATS=0\\n",
        checker_args=(),
    ):
        with TemporaryDirectory() as directory:
            fixture_root = Path(directory)
            (fixture_root / "tools").mkdir()
            (fixture_root / "User").mkdir()
            (fixture_root / "Core/Src").mkdir(parents=True)
            shutil.copy2(CHECKER, fixture_root / "tools/check_platform_wiring.sh")
            (fixture_root / "User/app_main.cpp").write_text(
                app_source, encoding="ascii"
            )
            (fixture_root / "DevC.ioc").write_text(
                ioc_source, encoding="ascii"
            )
            (fixture_root / "Core/Inc").mkdir(parents=True)
            (fixture_root / "Core/Inc/stm32f4xx_it.h").write_text(
                header, encoding="ascii"
            )
            (fixture_root / "Core/Inc/FreeRTOSConfig.h").write_text(
                runtime_stats_config, encoding="ascii"
            )
            (fixture_root / "Core/Src/main.c").write_text(
                gpio_source, encoding="ascii"
            )
            (fixture_root / "Core/Src/stm32f4xx_hal_msp.c").write_text(
                can_msp_source + i2c_msp_source, encoding="ascii"
            )
            (fixture_root / "Core/Src/stm32f4xx_it.c").write_text(
                source, encoding="ascii"
            )
            return subprocess.run(
                ["bash", "tools/check_platform_wiring.sh", *checker_args],
                cwd=fixture_root,
                capture_output=True,
                check=False,
                encoding="ascii",
            )

    def assert_rejected(self, source, expected_error, **kwargs):
        result = self.run_checker(source, **kwargs)
        self.assertEqual(result.returncode, 1)
        self.assertIn(expected_error, result.stderr)

    def test_accepts_complete_wiring_fixture(self):
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "PASS: platform wiring\n")

    def test_rejects_empty_exti1_handler(self):
        self.assert_rejected(
            IT_SOURCE.replace(
                "void EXTI1_IRQHandler(void) {\n  HAL_GPIO_EXTI_IRQHandler(IMU_INT_Pin);\n}",
                "void EXTI1_IRQHandler(void) {\n}",
            ),
            "missing: IMU HAL dispatch",
        )

    def test_rejects_empty_can1_sce_handler(self):
        self.assert_rejected(
            IT_SOURCE.replace(
                "void CAN1_SCE_IRQHandler(void) {\n  HAL_CAN_IRQHandler(&hcan1);\n}",
                "void CAN1_SCE_IRQHandler(void) {\n}",
            ),
            "missing: CAN1 HAL dispatch",
        )

    def test_rejects_empty_can2_sce_handler(self):
        self.assert_rejected(
            IT_SOURCE.replace(
                "void CAN2_SCE_IRQHandler(void) {\n  HAL_CAN_IRQHandler(&hcan2);\n}",
                "void CAN2_SCE_IRQHandler(void) {\n}",
            ),
            "missing: CAN2 HAL dispatch",
        )

    def test_rejects_wrong_can_handle_in_sce_handler(self):
        self.assert_rejected(
            IT_SOURCE.replace(
                "void CAN1_SCE_IRQHandler(void) {\n  HAL_CAN_IRQHandler(&hcan1);\n}",
                "void CAN1_SCE_IRQHandler(void) {\n  HAL_CAN_IRQHandler(&hcan2);\n}",
            ),
            "missing: CAN1 HAL dispatch",
        )

    def test_rejects_wrong_exti_pin_in_handler(self):
        self.assert_rejected(
            IT_SOURCE.replace("IMU_INT_Pin", "ACCL_INT_Pin", 1),
            "missing: IMU HAL dispatch",
        )

    def test_rejects_wrong_can2_handle_in_sce_handler(self):
        self.assert_rejected(
            IT_SOURCE.replace(
                "void CAN2_SCE_IRQHandler(void) {\n  HAL_CAN_IRQHandler(&hcan2);\n}",
                "void CAN2_SCE_IRQHandler(void) {\n  HAL_CAN_IRQHandler(&hcan1);\n}",
            ),
            "missing: CAN2 HAL dispatch",
        )

    def test_rejects_can1_sce_without_required_priority(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: CAN1 SCE priority",
            ioc_source="NVIC.EXTI1_IRQn=true\\:5\\:0\\nNVIC.CAN1_SCE_IRQn=true\\:4\\:0\\nNVIC.CAN2_SCE_IRQn=true\\:5\\:0\\n",
        )

    def test_rejects_missing_exti1_header_declaration(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: EXTI1 header declaration",
            header=IT_HEADER.replace("void EXTI1_IRQHandler(void);\n", ""),
        )

    def test_rejects_missing_can1_sce_header_declaration(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: CAN1 SCE header declaration",
            header=IT_HEADER.replace("void CAN1_SCE_IRQHandler(void);\n", ""),
        )

    def test_rejects_missing_can2_sce_header_declaration(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: CAN2 SCE header declaration",
            header=IT_HEADER.replace("void CAN2_SCE_IRQHandler(void);\n", ""),
        )

    def test_rejects_missing_exti1_nvic_enablement(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: EXTI1 NVIC",
            gpio_source="",
        )

    def test_rejects_missing_exti1_ioc_priority(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: EXTI1 priority",
            ioc_source="NVIC.CAN1_SCE_IRQn=true\\:5\\:0\\nNVIC.CAN2_SCE_IRQn=true\\:5\\:0\\n",
        )

    def test_rejects_wrong_exti1_ioc_priority(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: EXTI1 priority",
            ioc_source="NVIC.EXTI1_IRQn=true\\:4\\:0\\nNVIC.CAN1_SCE_IRQn=true\\:5\\:0\\nNVIC.CAN2_SCE_IRQn=true\\:5\\:0\\n",
        )

    def test_rejects_wrong_can2_sce_ioc_priority(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: CAN2 SCE priority",
            ioc_source="NVIC.EXTI1_IRQn=true\\:5\\:0\\nNVIC.CAN1_SCE_IRQn=true\\:5\\:0\\nNVIC.CAN2_SCE_IRQn=true\\:4\\:0\\n",
        )

    def test_rejects_i2c1_dma_enabled_registration(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: I2C1 truthful threshold",
            app_source=APP_SOURCE.replace(
                "static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = UINT32_MAX;\n",
                "",
            ).replace("I2C_DMA_DISABLED_THRESHOLD", "3"),
        )

    def test_rejects_i2c1_non_max_dma_disabled_threshold(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: I2C1 truthful threshold",
            app_source=APP_SOURCE.replace("UINT32_MAX", "3"),
        )

    def test_rejects_commented_correct_threshold_with_active_dma_threshold(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: I2C1 truthful threshold",
            app_source=APP_SOURCE.replace(
                "static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = UINT32_MAX;",
                "// static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = UINT32_MAX;\n"
                "static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = 3;",
            ),
        )

    def test_rejects_second_active_i2c1_threshold_declaration(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: I2C1 truthful threshold",
            app_source=APP_SOURCE.replace(
                "static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = UINT32_MAX;\n",
                "static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = UINT32_MAX;\n"
                "static constexpr uint32_t I2C_DMA_DISABLED_THRESHOLD = 3;\n",
            ),
        )

    def test_rejects_i2c1_dma_linkage(self):
        self.assert_rejected(
            IT_SOURCE,
            "unexpected: I2C1 DMA linkage",
            i2c_msp_source=I2C_MSP_SOURCE.replace(
                "}\n", "  __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c1_rx);\n}\n"
            ),
        )

    def test_ignores_commented_i2c1_dma_linkage(self):
        result = self.run_checker(
            i2c_msp_source=I2C_MSP_SOURCE.replace(
                "  }\n  else if", "    // __HAL_LINKDMA(hi2c, hdmarx, hdma_i2c1_rx);\n  }\n  else if"
            ),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_dma_linkage_in_reordered_i2c1_branch(self):
        self.assert_rejected(
            IT_SOURCE,
            "unexpected: I2C1 DMA linkage",
            i2c_msp_source=REORDERED_I2C_MSP_SOURCE,
        )

    def test_rejects_i2c1_branch_only_in_deinit(self):
        self.assert_rejected(
            IT_SOURCE,
            "unexpected: I2C1 DMA linkage",
            i2c_msp_source=DEINIT_ONLY_I2C_MSP_SOURCE,
        )

    def test_rejects_enabled_runtime_statistics(self):
        result = self.run_checker(
            checker_args=("--runtime-stats",),
            runtime_stats_config=RUNTIME_STATS_CONFIG.replace(
                "configGENERATE_RUN_TIME_STATS 0",
                "configGENERATE_RUN_TIME_STATS 1",
            ),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing: disabled runtime statistics config", result.stderr)

    def test_rejects_active_runtime_statistics_port_macro(self):
        result = self.run_checker(
            checker_args=("--runtime-stats",),
            runtime_stats_config=(
                RUNTIME_STATS_CONFIG
                + "#define portGET_RUN_TIME_COUNTER_VALUE getRunTimeCounterValue\n"
            ),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing: disabled runtime statistics config", result.stderr)

    def test_current_root_full_mode_and_i2c1_mode_are_green(self):
        full_result = subprocess.run(
            ["bash", str(CHECKER)],
            cwd=ROOT,
            capture_output=True,
            check=False,
            encoding="ascii",
        )
        focused_result = subprocess.run(
            ["bash", str(CHECKER), "--i2c1"],
            cwd=ROOT,
            capture_output=True,
            check=False,
            encoding="ascii",
        )
        self.assertEqual(full_result.returncode, 0, full_result.stderr)
        self.assertEqual(focused_result.returncode, 0, focused_result.stderr)

    def test_rejects_missing_can1_sce_nvic_enablement(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: CAN1 SCE NVIC",
            can_msp_source=CAN_MSP_SOURCE.replace(
                "HAL_NVIC_EnableIRQ(CAN1_SCE_IRQn);\n", ""
            ),
        )

    def test_rejects_missing_can2_sce_nvic_enablement(self):
        self.assert_rejected(
            IT_SOURCE,
            "missing: CAN2 SCE NVIC",
            can_msp_source=CAN_MSP_SOURCE.replace(
                "HAL_NVIC_EnableIRQ(CAN2_SCE_IRQn);\n", ""
            ),
        )


if __name__ == "__main__":
    unittest.main()
