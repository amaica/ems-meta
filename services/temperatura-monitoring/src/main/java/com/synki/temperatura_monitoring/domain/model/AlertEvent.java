package com.synki.temperatura_monitoring.domain.model;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.time.OffsetDateTime;

@Data
@Entity
@Builder
@AllArgsConstructor
@NoArgsConstructor
public class AlertEvent {

    @Id
    @AttributeOverride(name = "value", column = @Column(name = "id", columnDefinition = "uuid"))
    private AlertEventId id;

    @Embedded
    @AttributeOverride(name = "value", column = @Column(name = "sensor_id", columnDefinition = "bigint"))
    private SensorId sensorId;

    @Column(name = "\"value\"")
    private Double value;

    @Enumerated(EnumType.STRING)
    private AlertEventType type;

    private OffsetDateTime registeredAt;
}
