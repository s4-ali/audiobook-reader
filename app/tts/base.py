"""TTS engine interface."""
from __future__ import annotations

from abc import ABC, abstractmethod

import numpy as np


class TTSEngine(ABC):
    sample_rate: int = 24000
    name: str = "base"

    @abstractmethod
    def synth(self, text: str) -> np.ndarray:
        """Synthesize ``text`` -> float32 mono PCM at ``self.sample_rate``."""
        raise NotImplementedError

    def info(self) -> dict:
        return {"engine": self.name, "sample_rate": self.sample_rate}
