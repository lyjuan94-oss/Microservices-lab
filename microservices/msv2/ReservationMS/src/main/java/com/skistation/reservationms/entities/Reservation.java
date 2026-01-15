package com.skistation.reservationms.entities;
import jakarta.persistence.*;
import lombok.*;

import java.time.LocalDate;

@Entity
@Getter @Setter
@NoArgsConstructor
@AllArgsConstructor
@ToString
public class Reservation {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long idReservation;
    @Temporal(TemporalType.DATE)
    LocalDate startDate;
    @Temporal(TemporalType.DATE)
    LocalDate endDate;

    private String yearUniv;
    private boolean isValid;

    private Long studentId;
}
