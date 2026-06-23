package com.synki.temperatura_monitoring.domain.model;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.UUID;

@Data
@Embeddable
@NoArgsConstructor
@AllArgsConstructor
public class AlertEventId {

    @Column(columnDefinition = "uuid")
    private UUID value;

    public AlertEventId(String value) {
        this.value = UUID.fromString(value);
    }
}
