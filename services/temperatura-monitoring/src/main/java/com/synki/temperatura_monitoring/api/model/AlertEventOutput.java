package com.synki.temperatura_monitoring.api.model;

import com.synki.temperatura_monitoring.domain.model.AlertEventType;
import io.hypersistence.tsid.TSID;
import lombok.Builder;
import lombok.Data;

import java.time.OffsetDateTime;
import java.util.UUID;

@Data
@Builder
public class AlertEventOutput {
    private UUID id;
    private TSID sensorId;
    private Double value;
    private AlertEventType type;
    private OffsetDateTime registeredAt;
}
