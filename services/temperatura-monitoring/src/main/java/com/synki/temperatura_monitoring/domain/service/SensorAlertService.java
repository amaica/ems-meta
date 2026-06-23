package com.synki.temperatura_monitoring.domain.service;

import com.synki.temperatura_monitoring.api.model.TemperatureLogData;
import com.synki.temperatura_monitoring.domain.model.AlertEvent;
import com.synki.temperatura_monitoring.domain.model.AlertEventId;
import com.synki.temperatura_monitoring.domain.model.AlertEventType;
import com.synki.temperatura_monitoring.domain.model.SensorId;
import com.synki.temperatura_monitoring.domain.repository.AlertEventRepository;
import com.synki.temperatura_monitoring.domain.repository.SensorAlertRepository;
import jakarta.transaction.Transactional;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.time.OffsetDateTime;
import java.util.UUID;

@Service
@RequiredArgsConstructor
@Slf4j
public class SensorAlertService {

    private final SensorAlertRepository sensorAlertRepository;
    private final AlertEventRepository alertEventRepository;

    @Transactional
    public void handleAlert(TemperatureLogData temperatureLogData) {
        sensorAlertRepository.findById(new SensorId(temperatureLogData.getSensorId()))
                .ifPresentOrElse(alert -> {

                    if (alert.getMaxTemperature() != null
                            && temperatureLogData.getValue().compareTo(alert.getMaxTemperature()) >= 0) {
                        registerEvent(temperatureLogData, AlertEventType.MAX_EXCEEDED);
                        log.info("Alert Max Temp: SensorId {} Temp {}",
                                temperatureLogData.getSensorId(), temperatureLogData.getValue());
                    } else if (alert.getMinTemperature() != null
                            && temperatureLogData.getValue().compareTo(alert.getMinTemperature()) <= 0) {
                        registerEvent(temperatureLogData, AlertEventType.MIN_EXCEEDED);
                        log.info("Alert Min Temp: SensorId {} Temp {}",
                                temperatureLogData.getSensorId(), temperatureLogData.getValue());
                    } else {
                        logIgnoredAlert(temperatureLogData);
                    }

                }, () -> logIgnoredAlert(temperatureLogData));
    }

    private void registerEvent(TemperatureLogData temperatureLogData, AlertEventType type) {
        AlertEvent event = AlertEvent.builder()
                .id(new AlertEventId(UUID.randomUUID()))
                .sensorId(new SensorId(temperatureLogData.getSensorId()))
                .value(temperatureLogData.getValue())
                .type(type)
                .registeredAt(OffsetDateTime.now())
                .build();
        alertEventRepository.save(event);
    }

    private static void logIgnoredAlert(TemperatureLogData temperatureLogData) {
        log.info("Alert Ignored: SensorId {} Temp {}",
                temperatureLogData.getSensorId(), temperatureLogData.getValue());
    }

}
