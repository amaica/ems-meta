package com.synki.temperatura_monitoring.api.controller;

import com.synki.temperatura_monitoring.api.model.AlertEventOutput;
import com.synki.temperatura_monitoring.domain.model.AlertEvent;
import com.synki.temperatura_monitoring.domain.model.SensorId;
import com.synki.temperatura_monitoring.domain.repository.AlertEventRepository;
import io.hypersistence.tsid.TSID;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.web.PageableDefault;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/sensors/{sensorId}/alert/events")
@RequiredArgsConstructor
public class AlertEventController {

    private final AlertEventRepository alertEventRepository;

    @GetMapping
    public Page<AlertEventOutput> search(@PathVariable TSID sensorId,
                                         @PageableDefault(size = 20) Pageable pageable) {
        return alertEventRepository.findAllBySensorId(new SensorId(sensorId), pageable)
                .map(this::toOutput);
    }

    private AlertEventOutput toOutput(AlertEvent event) {
        return AlertEventOutput.builder()
                .id(event.getId().getValue())
                .sensorId(event.getSensorId().getValue())
                .value(event.getValue())
                .type(event.getType())
                .registeredAt(event.getRegisteredAt())
                .build();
    }
}
